// Package runner wraps scripts/load-gateway.sh — the per-cell shell
// driver that brings a gateway up, runs k6, captures docker stats,
// and tears the gateway down. Phase 6's Go orchestrator delegates
// the heavy lifting (compose up/down, k6 invocation, sidecars) to
// the proven shell driver and focuses on:
//
//   - timing and verdict accounting,
//   - watchdog (kill on hung cell),
//   - stdout streaming with prefixed lines so multiple cells stay
//     legible in the parent log,
//   - manifest stamping (per-cell record).
//
// A Watchdog timeout of zero disables the timer.
package runner

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
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
	Env      []string      // additional KEY=VAL pairs (e.g. WALLARM_IMAGE=…)
}

// Run executes one cell. The returned Result.Verdict reflects what we
// can detect from disk artefacts and the wrapper exit code; deeper
// classification (e.g. "all checks failed but rc=0") happens in
// internal/aggregate.
func (r *Runner) Run(ctx context.Context, cell matrix.Cell) Result {
	if r.Logger == nil {
		r.Logger = os.Stderr
	}
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

	cmd := exec.CommandContext(runCtx, "bash", args...)
	cmd.Dir = r.RepoRoot
	cmd.Env = append(os.Environ(), append([]string{
		"RUN_ID=" + r.RunID,
		fmt.Sprintf("BENCH_RUN_SEED=%d", r.Seed),
	}, r.Env...)...)

	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()

	if err := cmd.Start(); err != nil {
		return Result{
			Cell:      cell,
			Verdict:   VerdictFail,
			OutputDir: outputDir,
			Error:     fmt.Sprintf("start load-gateway.sh: %v", err),
			StartedAt: startedAt,
			EndedAt:   time.Now().UTC(),
		}
	}

	prefix := fmt.Sprintf("[%s] ", cell.ID())
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); pipeWithPrefix(r.Logger, stdout, prefix) }()
	go func() { defer wg.Done(); pipeWithPrefix(r.Logger, stderr, prefix) }()

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
	}

	switch {
	case timedOut:
		res.Verdict = VerdictTimeout
		res.Error = fmt.Sprintf("watchdog timeout after %s", r.Watchdog)
	case fileNonEmpty(filepath.Join(r.RepoRoot, outputDir, "k6-summary.json")):
		res.Verdict = VerdictPass
	case fileNonEmpty(filepath.Join(r.RepoRoot, outputDir, "excluded.json")):
		res.Verdict = VerdictExcluded
	case rc != 0 && waitErr != nil:
		res.Verdict = VerdictFail
		res.Error = waitErr.Error()
	default:
		res.Verdict = VerdictFail
		res.Error = "no k6-summary.json and no excluded.json on disk"
	}
	return res
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
