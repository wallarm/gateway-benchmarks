package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/readiness"
)

// awsFetchInput is the JSON shape consumed on stdin. The bash caller
// derives it from `tofu output -json cluster_shards` plus a few path
// constants the orchestrator already knows.
type awsFetchInput struct {
	SSHOptions string            `json:"ssh_options"`
	RemoteDir  string            `json:"remote_dir"`
	LocalDir   string            `json:"local_dir"`
	Clusters   []awsFetchCluster `json:"clusters"`
}

type awsFetchCluster struct {
	Index      int    `json:"index"`
	LoadgenSSH string `json:"loadgen_ssh"`
	ShardID    string `json:"shard_id"`
}

func newAWSFetchCmd() *cobra.Command {
	var (
		concurrency  int
		maxAttempts  int
		timeout      time.Duration
		pollInterval time.Duration
		logDir       string
	)

	cmd := &cobra.Command{
		Use:   "aws-fetch",
		Short: "Pull per-shard report tarballs from every AWS loadgen in parallel",
		Long: "aws-fetch replaces the sequential per-shard fetch loop in\n" +
			"scripts/perf-aws-full-report.sh with a goroutine pool. For each\n" +
			"shard the helper runs:\n" +
			"\n" +
			"  rm -rf <local-dir>/<shard-id>\n" +
			"  ssh <loadgen> 'cd <remote-dir> && tar -czf - <shard-id>' \\\n" +
			"    | tar -C <local-dir> -xzf -\n" +
			"\n" +
			"Concurrency caps the number of parallel ssh-tar pipes so the\n" +
			"operator's download bandwidth and disk I/O don't saturate on a\n" +
			"large fleet. MaxAttempts=2 absorbs a single network blip without\n" +
			"re-fetching the same shard tarball indefinitely.\n" +
			"\n" +
			"Per-shard combined output is captured to <log-dir>/fetch-<NN>.log\n" +
			"so a failure can be diagnosed without losing the tar / ssh stderr.\n" +
			"\n" +
			"Exit 0 = every shard fetched; 1 = at least one failed.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runAWSFetch(cmd.Context(), os.Stdin, os.Stderr,
				concurrency, maxAttempts, timeout, pollInterval, logDir)
		},
	}

	cmd.Flags().IntVar(&concurrency, "concurrency", 6,
		"max shards fetched simultaneously; cap parallel downloads against operator's bandwidth + disk I/O")
	cmd.Flags().IntVar(&maxAttempts, "max-attempts", 2,
		"retries per shard (1 = no retry; default 2 absorbs a single network blip)")
	cmd.Flags().DurationVar(&timeout, "timeout", 10*time.Minute,
		"per-shard wall-clock budget across the ssh-tar pipe + retries")
	cmd.Flags().DurationVar(&pollInterval, "retry-interval", 5*time.Second,
		"sleep between retries on the same shard (only used when an attempt fails)")
	cmd.Flags().StringVar(&logDir, "log-dir", "",
		"directory for per-shard fetch-<NN>.log files (default: stderr-only)")

	return cmd
}

func runAWSFetch(
	ctx context.Context,
	stdin io.Reader,
	progressOut io.Writer,
	concurrency, maxAttempts int,
	timeout, pollInterval time.Duration,
	logDir string,
) error {
	raw, err := io.ReadAll(stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	var input awsFetchInput
	if err := json.Unmarshal(raw, &input); err != nil {
		return fmt.Errorf("parse fetch input JSON: %w", err)
	}
	if len(input.Clusters) == 0 {
		return fmt.Errorf("fetch input contains zero clusters")
	}
	if input.RemoteDir == "" {
		input.RemoteDir = "/opt/gateway-benchmarks/reports"
	}
	if input.LocalDir == "" {
		input.LocalDir = "reports"
	}
	if err := os.MkdirAll(input.LocalDir, 0o755); err != nil {
		return fmt.Errorf("mkdir local-dir %q: %w", input.LocalDir, err)
	}
	if logDir != "" {
		if err := os.MkdirAll(logDir, 0o755); err != nil {
			return fmt.Errorf("mkdir log-dir: %w", err)
		}
	}

	// Validate ssh-lines up front (review finding H3).
	allLines := make([]string, 0, len(input.Clusters))
	for _, c := range input.Clusters {
		allLines = append(allLines, c.LoadgenSSH)
	}
	if err := validateSSHLines(allLines, input.SSHOptions); err != nil {
		return fmt.Errorf("ssh-line validation: %w", err)
	}

	probes := make([]readiness.Probe, 0, len(input.Clusters))
	for _, c := range input.Clusters {
		label := fmt.Sprintf("shard %02d (%s)", c.Index, c.ShardID)
		var logPath string
		if logDir != "" {
			logPath = filepath.Join(logDir, fmt.Sprintf("fetch-%02d.log", c.Index))
		}
		loadgenSSH, _ := injectSSHOptions(c.LoadgenSSH, input.SSHOptions)
		probes = append(probes, readiness.Probe{
			Label: label,
			Run: newShardFetchProbe(
				loadgenSSH, input.RemoteDir, input.LocalDir, c.ShardID, logPath),
		})
	}

	fmt.Fprintf(progressOut, "▶ Fetching %d shards (concurrency %d, retries up to %d, per-shard timeout %s)\n",
		len(probes), concurrency, maxAttempts, timeout)

	cfg := readiness.Config{
		PollInterval:  pollInterval,
		Timeout:       timeout,
		MaxAttempts:   maxAttempts,
		Concurrency:   concurrency,
		ProgressEvery: 10 * time.Second,
		Progress: func(s readiness.Snapshot) {
			fmt.Fprintf(progressOut, "  [%s] %d/%d fetched · %d in flight or queued · %d failed\n",
				fmtDuration(s.Elapsed), s.Ready, s.Total, s.Waiting, s.Failed)
		},
	}

	results, waitErr := readiness.Wait(ctx, probes, cfg)

	for _, r := range results {
		if r.Ready {
			fmt.Fprintf(progressOut, "  ✓ %s — fetched (attempt %d, %s)\n",
				r.Label, r.Attempts, fmtDuration(r.Duration))
			continue
		}
		fmt.Fprintf(progressOut, "  ✗ %s — FAILED after %d attempt(s) (%s): %v\n",
			r.Label, r.Attempts, fmtDuration(r.Duration), r.LastErr)
	}

	if waitErr != nil {
		return waitErr
	}
	fmt.Fprintln(progressOut, "✓ Fetch shard reports complete")
	return nil
}

// newShardFetchProbe composes the ssh-tar-pipe shell line once and
// returns a closure that re-runs it on each attempt. We rm -rf the
// local target before the extraction so a partial fetch from a
// previous attempt can never bleed into the new copy.
func newShardFetchProbe(loadgenSSH, remoteDir, localDir, shardID, logPath string) func(ctx context.Context) error {
	wipeAndExtract := fmt.Sprintf(
		"rm -rf %s && %s %s | tar -C %s -xzf -",
		shellQuote(filepath.Join(localDir, shardID)),
		loadgenSSH,
		shellQuote(fmt.Sprintf("cd %s && tar -czf - %s", shellQuote(remoteDir), shellQuote(shardID))),
		shellQuote(localDir),
	)

	return func(ctx context.Context) error {
		var logFile *os.File
		if logPath != "" {
			f, err := os.OpenFile(logPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
			if err != nil {
				return fmt.Errorf("open fetch log %q: %w", logPath, err)
			}
			defer f.Close()
			logFile = f
		}

		cmd := exec.CommandContext(ctx, "sh", "-c", wipeAndExtract)
		out, err := cmd.CombinedOutput()
		if logFile != nil {
			ts := time.Now().UTC().Format("15:04:05")
			fmt.Fprintf(logFile, "[%s] === fetch %s ===\n", ts, shardID)
			if len(out) > 0 {
				logFile.Write(out)
				if out[len(out)-1] != '\n' {
					fmt.Fprintln(logFile)
				}
			}
			if err != nil {
				fmt.Fprintf(logFile, "[%s] fetch FAILED: %v\n", ts, err)
			} else {
				fmt.Fprintf(logFile, "[%s] fetch OK\n", ts)
			}
		}
		return err
	}
}
