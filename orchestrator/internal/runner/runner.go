// Package runner wraps scripts/load-gateway.sh — the per-cell shell
// driver that brings a gateway up, runs k6, and tears the gateway
// down. Phase 6's Go orchestrator delegates the heavy lifting
// (compose up/down, k6 invocation) to the proven shell driver and
// focuses on:
//
//   - timing and verdict accounting,
//   - watchdog (kill on hung cell),
//   - native per-second docker-stats sampling via
//     internal/stats.Collector (the shell sidecar is suppressed by
//     exporting BENCH_SKIP_DOCKER_STATS=1 into the child env),
//   - gateway-crash detection via the gateway-crash.json sentinel
//     written by load-gateway.sh; CRASHED is distinguished from
//     FAIL and can be retried via RetryOnCrash,
//   - stdout streaming with prefixed lines so multiple cells stay
//     legible in the parent log,
//   - manifest stamping (per-cell record).
//
// A Watchdog timeout of zero disables the timer.
package runner

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/stats"
)

// Verdict mirrors load-orchestrator.sh's terminal states. CRASHED is
// new in Phase 6 — the Go layer can distinguish "k6 ran to completion
// but with all 5xx" (PASS at this layer, ranking is downstream) from
// "the gateway never came back up" (CRASHED).
type Verdict string

const (
	VerdictPass     Verdict = "PASS"
	VerdictExcluded Verdict = "EXCLUDED"
	VerdictFail     Verdict = "FAIL"
	VerdictCrashed  Verdict = "CRASHED"
	VerdictTimeout  Verdict = "TIMEOUT"
)

// Result is the per-cell record persisted into cells.jsonl /
// matrix.tsv after each cell.
type Result struct {
	Cell      matrix.Cell `json:"cell"`
	Verdict   Verdict     `json:"verdict"`
	Duration  float64     `json:"duration_sec"`
	OutputDir string      `json:"output_dir"`
	ExitCode  int         `json:"exit_code"`
	Error     string      `json:"error,omitempty"`
	StartedAt time.Time   `json:"started_at"`
	EndedAt   time.Time   `json:"ended_at"`

	// Attempts is the number of load-gateway.sh invocations the
	// Runner made for this cell. 1 = single run, >1 = retried (see
	// RetryOnCrash). Always 0 for parity-gated rejections where
	// Run was never called.
	Attempts int `json:"attempts,omitempty"`

	// GatewayCrash, when set, is the parsed gateway-crash.json
	// sentinel written by load-gateway.sh. Only present when
	// Verdict == CRASHED.
	GatewayCrash *GatewayCrashInfo `json:"gateway_crash,omitempty"`
}

// GatewayCrashInfo mirrors the gateway-crash.json sentinel produced
// by scripts/load-gateway.sh when the gateway container exits mid-
// run. Only the fields the orchestrator actually consumes are
// declared — any extra keys in the file are ignored.
type GatewayCrashInfo struct {
	Container  string `json:"container"`
	Status     string `json:"status"`
	ExitCode   int    `json:"exit_code"`
	OOMKilled  bool   `json:"oom_killed"`
	FinishedAt string `json:"finished_at"`
	Error      string `json:"error,omitempty"`
}

// Runner holds the invariants shared across cells of one sweep.
type Runner struct {
	RepoRoot string
	RunID    string
	Seed     int64
	Stream   bool          // pass --stream to load-gateway.sh
	KeepUp   bool          // pass --keep-up
	Watchdog time.Duration // zero = disabled
	Logger   io.Writer     // defaults to os.Stderr
	Verbose  bool          // stream child stdout/stderr
	Env      []string      // additional KEY=VAL pairs (e.g. WALLARM_IMAGE=…)

	// RetryOnCrash is the number of *additional* attempts after the
	// first one for a cell that ends CRASHED. Default 0 = no retry,
	// first crash is terminal. 1 = one retry (total 2 attempts).
	// TIMEOUT and FAIL are never retried — only CRASHED.
	RetryOnCrash int

	// DisableNativeStats skips the native Go docker-stats collector
	// (falling back to the shell sidecar inside load-gateway.sh).
	// Default false — the Go collector is preferred because it
	// removes the bash/curl/jq dependency from the gateway host and
	// keeps the sampling lifecycle inside the orchestrator.
	DisableNativeStats bool

	// StatsInterval overrides the collector sample interval. Zero
	// defaults to 1s (matches the shell sidecar).
	StatsInterval time.Duration

	// StatsSocket overrides the Docker socket path used by the
	// native collector. Empty = auto-probe (DOCKER_HOST_SOCK,
	// ~/.docker/run/docker.sock, /var/run/docker.sock).
	StatsSocket string
}

// Run executes one cell, honouring RetryOnCrash: a cell that ends
// CRASHED is retried up to RetryOnCrash additional times; TIMEOUT
// and FAIL are never retried (those require operator intervention).
// The returned Result.Verdict reflects the last attempt's outcome;
// Attempts records the total number of attempts.
//
// Deeper classification (e.g. "all checks failed but rc=0") happens
// in internal/aggregate on top of the per-cell artefacts on disk.
func (r *Runner) Run(ctx context.Context, cell matrix.Cell) Result {
	if r.Logger == nil {
		r.Logger = os.Stderr
	}
	res := r.runOnce(ctx, cell, 1)
	attempts := res.Attempts
	for res.Verdict == VerdictCrashed && r.RetryOnCrash > 0 && attempts <= r.RetryOnCrash {
		fmt.Fprintf(r.Logger, "[%s] CRASHED on attempt %d — retrying (max %d)\n",
			cell.ID(), attempts, r.RetryOnCrash+1)
		// Clear the crash sentinel so the retry's detection is clean.
		_ = os.Remove(filepath.Join(r.RepoRoot, cell.OutputDir(r.RunID), "gateway-crash.json"))
		attempts++
		res = r.runOnce(ctx, cell, attempts)
	}
	res.Attempts = attempts
	return res
}

// runOnce is a single load-gateway.sh invocation — the inner loop
// Run calls once per attempt.
func (r *Runner) runOnce(ctx context.Context, cell matrix.Cell, attempt int) Result {
	outputDir := cell.OutputDir(r.RunID)
	startedAt := time.Now().UTC()

	args := []string{
		"scripts/load-gateway.sh",
		"--gateway", cell.Gateway,
		"--policy", cell.Policy,
		"--scenario", cell.Scenario,
		"--load", cell.Load,
		"--output", outputDir,
		"--seed", fmt.Sprintf("%d", r.Seed),
	}
	if r.Stream {
		args = append(args, "--stream")
	}
	if r.KeepUp {
		args = append(args, "--keep-up")
	}

	runCtx := ctx
	var cancel context.CancelFunc
	if r.Watchdog > 0 {
		runCtx, cancel = context.WithTimeout(ctx, r.Watchdog)
		defer cancel()
	}

	// Spawn the native stats collector concurrently with the
	// load-gateway.sh invocation, but only if the operator hasn't
	// opted out. The collector polls the Docker socket for
	// `gwb-<gateway>` and writes reports/<run>/raw/<cell>/docker-stats.csv
	// — the shell sidecar is suppressed via BENCH_SKIP_DOCKER_STATS=1.
	absOutputDir := filepath.Join(r.RepoRoot, outputDir)
	statsStop := r.startStatsCollector(runCtx, cell, absOutputDir)
	defer statsStop()

	cmd := exec.CommandContext(runCtx, "bash", args...)
	cmd.Dir = r.RepoRoot
	childEnv := []string{
		"RUN_ID=" + r.RunID,
		fmt.Sprintf("BENCH_RUN_SEED=%d", r.Seed),
		// Always ask load-gateway.sh to write gateway-crash.json on
		// a mid-run container exit — the shell logic is a no-op
		// when the gateway stays up, so this is free when enabled.
		"BENCH_CHECK_GATEWAY_CRASH=1",
	}
	if !r.DisableNativeStats {
		childEnv = append(childEnv, "BENCH_SKIP_DOCKER_STATS=1")
	}
	cmd.Env = append(os.Environ(), append(childEnv, r.Env...)...)

	var (
		stdout    io.ReadCloser
		stderr    io.ReadCloser
		stdoutBuf bytes.Buffer
		stderrBuf bytes.Buffer
	)
	if r.Verbose {
		stdout, _ = cmd.StdoutPipe()
		stderr, _ = cmd.StderrPipe()
	} else {
		cmd.Stdout = &stdoutBuf
		cmd.Stderr = &stderrBuf
	}

	if err := cmd.Start(); err != nil {
		return Result{
			Cell:      cell,
			Verdict:   VerdictFail,
			OutputDir: outputDir,
			Error:     fmt.Sprintf("start load-gateway.sh: %v", err),
			StartedAt: startedAt,
			EndedAt:   time.Now().UTC(),
			Attempts:  attempt,
		}
	}

	var wg sync.WaitGroup
	if r.Verbose {
		prefix := fmt.Sprintf("[%s] ", cell.ID())
		wg.Add(2)
		go func() { defer wg.Done(); pipeWithPrefix(r.Logger, stdout, prefix) }()
		go func() { defer wg.Done(); pipeWithPrefix(r.Logger, stderr, prefix) }()
	}

	waitErr := cmd.Wait()
	wg.Wait()

	endedAt := time.Now().UTC()
	rc := 0
	timedOut := false
	if waitErr != nil {
		var ee *exec.ExitError
		if errors.As(waitErr, &ee) {
			rc = ee.ExitCode()
		} else {
			rc = -1
		}
	}
	if runCtx.Err() == context.DeadlineExceeded {
		timedOut = true
	}

	res := Result{
		Cell:      cell,
		Duration:  endedAt.Sub(startedAt).Seconds(),
		OutputDir: outputDir,
		ExitCode:  rc,
		StartedAt: startedAt,
		EndedAt:   endedAt,
		Attempts:  attempt,
	}

	// Crash sentinel beats everything except TIMEOUT — a gateway
	// crash can cause load-gateway.sh to exit non-zero even when
	// k6 itself ran to completion, and we want those flagged
	// CRASHED (distinct from FAIL) for the retry loop and the
	// ranking penalty.
	crash := loadCrashSentinel(filepath.Join(r.RepoRoot, outputDir, "gateway-crash.json"))

	switch {
	case timedOut:
		res.Verdict = VerdictTimeout
		res.Error = fmt.Sprintf("watchdog timeout after %s", r.Watchdog)
	case crash != nil:
		res.Verdict = VerdictCrashed
		res.GatewayCrash = crash
		res.Error = formatCrashError(crash)
	case fileNonEmpty(filepath.Join(r.RepoRoot, outputDir, "k6-summary.json")):
		res.Verdict = VerdictPass
	case fileNonEmpty(filepath.Join(r.RepoRoot, outputDir, "excluded.json")):
		res.Verdict = VerdictExcluded
	case rc != 0 && waitErr != nil:
		res.Verdict = VerdictFail
		res.Error = fallbackChildError(compactChildOutput(stderrBuf.String(), stdoutBuf.String()), waitErr.Error())
	default:
		res.Verdict = VerdictFail
		res.Error = fallbackChildError(
			compactChildOutput(stderrBuf.String(), stdoutBuf.String()),
			"no k6-summary.json and no excluded.json on disk",
		)
	}
	return res
}

// startStatsCollector launches the native Go docker-stats sampler
// for this cell and returns a stop func that blocks until the
// sampler has flushed its CSV. A no-op stop is returned when native
// stats are disabled or the collector failed to start — neither is
// treated as a fatal error for the cell (the cell just ends without
// resource-usage data, same as an unreachable socket with the shell
// sidecar).
func (r *Runner) startStatsCollector(ctx context.Context, cell matrix.Cell, outputDirAbs string) func() {
	if r.DisableNativeStats {
		return func() {}
	}
	c := &stats.Collector{
		Container: "gwb-" + cell.Gateway,
		Output:    filepath.Join(outputDirAbs, "docker-stats.csv"),
		Interval:  r.StatsInterval,
		Socket:    r.StatsSocket,
		// 3 minutes covers the slowest cold-start gateway in the
		// catalogue (APISIX standalone with etcd dependency, ~75s
		// observed on c6i.2xlarge cold cache; wallarm stack ~50s).
		// 60s used to be the default and bit us during the v0.1.0
		// AWS canonical bring-up — the collector gave up before
		// compose up finished and docker-stats.csv was missing
		// for every cell, leaving CPU/memory/bandwidth columns at
		// zero in the wide CSV.
		StartupTimeout: 3 * time.Minute,
		Logger: func(format string, args ...any) {
			if r.Verbose {
				fmt.Fprintf(r.Logger, "[%s] stats: "+format+"\n", append([]any{cell.ID()}, args...)...)
			}
		},
	}
	stop, err := c.Start(ctx)
	if err != nil {
		if r.Verbose {
			fmt.Fprintf(r.Logger, "[%s] stats: collector disabled (%v)\n", cell.ID(), err)
		}
		return func() {}
	}
	return stop
}

// loadCrashSentinel reads gateway-crash.json if present. Returns nil
// on any read/parse failure — treated as "no crash detected".
func loadCrashSentinel(path string) *GatewayCrashInfo {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var info GatewayCrashInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return nil
	}
	return &info
}

func formatCrashError(c *GatewayCrashInfo) string {
	parts := []string{
		fmt.Sprintf("gateway container %q exited with status=%s exit_code=%d",
			c.Container, c.Status, c.ExitCode),
	}
	if c.OOMKilled {
		parts = append(parts, "oom_killed=true")
	}
	if c.Error != "" {
		parts = append(parts, c.Error)
	}
	return strings.Join(parts, "; ")
}

func pipeWithPrefix(dst io.Writer, src io.Reader, prefix string) {
	scanner := bufio.NewScanner(src)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		fmt.Fprintf(dst, "%s%s\n", prefix, scanner.Text())
	}
}

func fileNonEmpty(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.Size() > 0
}

func compactChildOutput(stderr, stdout string) string {
	out := strings.TrimSpace(stripANSI(stderr))
	if out == "" {
		out = strings.TrimSpace(stripANSI(stdout))
	}
	if out == "" {
		return ""
	}
	lines := strings.FieldsFunc(out, func(r rune) bool {
		return r == '\n' || r == '\r'
	})
	parts := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts = append(parts, line)
	}
	if len(parts) > 3 {
		parts = parts[len(parts)-3:]
	}
	out = strings.Join(parts, " | ")
	if len(out) > 240 {
		out = out[:237] + "..."
	}
	return out
}

func fallbackChildError(preferred, fallback string) string {
	if strings.TrimSpace(preferred) != "" {
		return preferred
	}
	return fallback
}

var ansiPattern = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)

func stripANSI(s string) string {
	return ansiPattern.ReplaceAllString(s, "")
}
