package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/readiness"
)

// awsSyncInput is the JSON shape consumed on stdin. The bash caller
// constructs it from `tofu output -json cluster_shards` plus the
// shared SSH-hardening options and the local repo metadata.
type awsSyncInput struct {
	SSHOptions  string           `json:"ssh_options"`
	RepoRoot    string           `json:"repo_root"`
	TarExcludes []string         `json:"tar_excludes"`
	KeyPath     string           `json:"key_path"`
	RemotePath  string           `json:"remote_path"`
	Clusters    []awsSyncCluster `json:"clusters"`
}

type awsSyncCluster struct {
	Index            int    `json:"index"`
	LoadgenSSH       string `json:"loadgen_ssh"`
	GatewaySSH       string `json:"gateway_ssh"`
	GatewayPrivateIP string `json:"gateway_private_ip"`
}

func newAWSSyncCmd() *cobra.Command {
	var (
		concurrency  int
		maxAttempts  int
		timeout      time.Duration
		pollInterval time.Duration
		logDir       string
	)

	cmd := &cobra.Command{
		Use:   "aws-sync",
		Short: "Push the repo checkout + SSH key to every AWS cluster in parallel",
		Long: "aws-sync replaces the per-cluster sync loop in\n" +
			"scripts/perf-aws-full-report.sh with a goroutine pool that runs\n" +
			"all clusters concurrently (capped by --concurrency to keep the\n" +
			"operator's uplink from saturating on a 22-cluster fleet). For\n" +
			"each cluster the helper performs four sequential operations:\n" +
			"\n" +
			"  1. tar -czf - . | ssh loadgen 'tar -xzf -' (deploy code)\n" +
			"  2. tar -czf - . | ssh gateway 'tar -xzf -' (deploy code)\n" +
			"  3. cat key | ssh loadgen 'cat > ~/.ssh/gwb_cluster_key'\n" +
			"  4. ssh loadgen 'ssh gateway true' (preflight loadgen->gateway)\n" +
			"\n" +
			"Steps within one cluster are sequential because step 4 depends\n" +
			"on step 3, and steps 1/2 must complete before the loadgen tries\n" +
			"to drive the gateway. Across clusters everything fans out.\n" +
			"\n" +
			"Per-cluster output is captured to <log-dir>/sync-<NN>.log so a\n" +
			"failure can be diagnosed without losing the tar / ssh stderr.\n" +
			"\n" +
			"Exit 0 = every cluster synced; 1 = at least one failed.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runAWSSync(cmd.Context(), os.Stdin, os.Stderr,
				concurrency, maxAttempts, timeout, pollInterval, logDir)
		},
	}

	cmd.Flags().IntVar(&concurrency, "concurrency", 6,
		"max clusters synced simultaneously; balances parallelism against the operator's uplink budget")
	cmd.Flags().IntVar(&maxAttempts, "max-attempts", 2,
		"retries per cluster (1 = no retry; default 2 absorbs a single network blip)")
	cmd.Flags().DurationVar(&timeout, "timeout", 10*time.Minute,
		"per-cluster wall-clock budget across all 4 steps + retries")
	cmd.Flags().DurationVar(&pollInterval, "retry-interval", 5*time.Second,
		"sleep between retries on the same cluster (only used when an attempt fails)")
	cmd.Flags().StringVar(&logDir, "log-dir", "",
		"directory for per-cluster sync-<NN>.log files (default: stderr-only)")

	return cmd
}

func runAWSSync(
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
	var input awsSyncInput
	if err := json.Unmarshal(raw, &input); err != nil {
		return fmt.Errorf("parse sync input JSON: %w", err)
	}
	if len(input.Clusters) == 0 {
		return fmt.Errorf("sync input contains zero clusters")
	}
	if input.RepoRoot == "" {
		return fmt.Errorf("sync input missing repo_root")
	}
	if input.KeyPath == "" {
		return fmt.Errorf("sync input missing key_path")
	}
	if input.RemotePath == "" {
		input.RemotePath = "/opt/gateway-benchmarks"
	}
	if logDir != "" {
		if err := os.MkdirAll(logDir, 0o755); err != nil {
			return fmt.Errorf("mkdir log-dir: %w", err)
		}
	}

	// Validate ssh-lines up front (review finding H3).
	allLines := make([]string, 0, len(input.Clusters)*2)
	for _, c := range input.Clusters {
		allLines = append(allLines, c.LoadgenSSH, c.GatewaySSH)
	}
	if err := validateSSHLines(allLines, input.SSHOptions); err != nil {
		return fmt.Errorf("ssh-line validation: %w", err)
	}

	probes := make([]readiness.Probe, 0, len(input.Clusters))
	for _, c := range input.Clusters {
		label := fmt.Sprintf("cluster %d", c.Index)
		var logPath string
		if logDir != "" {
			logPath = filepath.Join(logDir, fmt.Sprintf("sync-%02d.log", c.Index))
		}
		loadgenSSH, _ := injectSSHOptions(c.LoadgenSSH, input.SSHOptions)
		gatewaySSH, _ := injectSSHOptions(c.GatewaySSH, input.SSHOptions)
		probes = append(probes, readiness.Probe{
			Label: label,
			Run:   newClusterSyncProbe(input.RepoRoot, input.TarExcludes, input.RemotePath, input.KeyPath, c.GatewayPrivateIP, input.SSHOptions, loadgenSSH, gatewaySSH, logPath),
		})
	}

	fmt.Fprintf(progressOut, "▶ Syncing %d clusters (concurrency %d, retries up to %d, per-cluster timeout %s)\n",
		len(probes), concurrency, maxAttempts, timeout)

	cfg := readiness.Config{
		PollInterval:  pollInterval,
		Timeout:       timeout,
		MaxAttempts:   maxAttempts,
		Concurrency:   concurrency,
		ProgressEvery: 10 * time.Second,
		Progress: func(s readiness.Snapshot) {
			fmt.Fprintf(progressOut, "  [%s] %d/%d synced · %d in flight or queued · %d failed\n",
				fmtDuration(s.Elapsed), s.Ready, s.Total, s.Waiting, s.Failed)
		},
	}

	results, waitErr := readiness.Wait(ctx, probes, cfg)

	for _, r := range results {
		if r.Ready {
			fmt.Fprintf(progressOut, "  ✓ %s — synced (attempt %d, %s)\n",
				r.Label, r.Attempts, fmtDuration(r.Duration))
			continue
		}
		fmt.Fprintf(progressOut, "  ✗ %s — FAILED after %d attempt(s) (%s): %v\n",
			r.Label, r.Attempts, fmtDuration(r.Duration), r.LastErr)
	}

	if waitErr != nil {
		return waitErr
	}
	fmt.Fprintln(progressOut, "✓ Sync checkout complete")
	return nil
}

// newClusterSyncProbe wires Probe.Run to four sequential shell
// pipelines that mirror the previous bash flow byte-for-byte. We
// shell out via `sh -c` for the same reasons as aws-readiness — the
// SSH options, sudo invocation, and tar flags are already debugged in
// the bash version, so reusing the literal command lines minimises
// behaviour drift while we move the dispatch layer to Go.
func newClusterSyncProbe(
	repoRoot string,
	tarExcludes []string,
	remotePath, keyPath, gatewayPrivateIP, sshOptions, loadgenSSH, gatewaySSH, logPath string,
) func(ctx context.Context) error {
	excludeFlags := strings.Builder{}
	for _, e := range tarExcludes {
		excludeFlags.WriteString(" --exclude=")
		excludeFlags.WriteString(shellQuote(e))
	}

	// Remote shell deployed on each host: wipe + extract atomically
	// under sudo, then chown back to ubuntu so the orchestrator can
	// edit files without privilege escalation later.
	remoteDeploy := fmt.Sprintf(
		"sudo rm -rf %[1]s && sudo mkdir -p %[1]s && sudo tar --warning=no-unknown-keyword -xzf - -C %[1]s && sudo chown -R ubuntu:ubuntu %[1]s",
		shellQuote(remotePath))

	// Build each step as a self-contained `sh -c` line. We capture
	// stdout+stderr to a per-cluster log when logPath is set; the
	// orchestrator returns only an error string upward so progress
	// output stays compact.
	tarCmd := fmt.Sprintf("COPYFILE_DISABLE=1 tar --no-xattrs%s -czf - -C %s .",
		excludeFlags.String(), shellQuote(repoRoot))

	step1 := fmt.Sprintf("(%s) | %s %s", tarCmd, loadgenSSH, shellQuote(remoteDeploy))
	step2 := fmt.Sprintf("(%s) | %s %s", tarCmd, gatewaySSH, shellQuote(remoteDeploy))

	keyInstall := fmt.Sprintf("%s %s < %s",
		loadgenSSH,
		shellQuote("mkdir -p ~/.ssh && cat > ~/.ssh/gwb_cluster_key && chmod 600 ~/.ssh/gwb_cluster_key"),
		shellQuote(keyPath))

	// Inner ssh: loadgen → gateway. Reuses the same hardening options
	// the outer ssh got (StrictHostKeyChecking=no etc) so the bench
	// host's known_hosts churn doesn't bleed into the EC2 → EC2 hop.
	innerSSHOpts := sshOptions
	if innerSSHOpts == "" {
		innerSSHOpts = "-o BatchMode=yes -o ConnectTimeout=10"
	}
	preflight := fmt.Sprintf("%s %s",
		loadgenSSH,
		shellQuote(fmt.Sprintf("ssh -i ~/.ssh/gwb_cluster_key %s ubuntu@%s true",
			innerSSHOpts, gatewayPrivateIP)))

	// Per-attempt step descriptors. Closure-captured so successful
	// steps from earlier attempts persist across retries — critical
	// for the bandwidth budget (review finding H1): without this,
	// retrying a probe that succeeded on steps 1+2 (the 30 MB
	// tarball uploads) but failed on step 4 (preflight) would
	// re-upload both tarballs, doubling the burst on every retry.
	// Each step is idempotent on its own (steps 1+2 are
	// `rm -rf && tar -xzf`, step 3 is `cat > key && chmod`,
	// step 4 is `ssh ... true`), so skipping completed steps is
	// safe — and the recovered tail is exactly what failed.
	steps := []struct {
		name string
		line string
		done bool
	}{
		{name: "sync-loadgen", line: step1},
		{name: "sync-gateway", line: step2},
		{name: "install-key", line: keyInstall},
		{name: "preflight-loadgen-to-gateway", line: preflight},
	}

	// O_APPEND (vs O_TRUNC earlier) so a retry's log appends after
	// the first attempt's failure trail — easier postmortem than
	// "log only shows the last attempt's stderr" (review M6).
	return func(ctx context.Context) error {
		var logFile *os.File
		if logPath != "" {
			f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
			if err != nil {
				return fmt.Errorf("open sync log %q: %w", logPath, err)
			}
			defer f.Close()
			logFile = f
		}

		for i := range steps {
			if steps[i].done {
				if logFile != nil {
					ts := time.Now().UTC().Format("15:04:05")
					fmt.Fprintf(logFile, "[%s] === %s SKIPPED (succeeded on previous attempt) ===\n",
						ts, steps[i].name)
				}
				continue
			}
			// Bail before launching a subprocess if ctx is already
			// cancelled — saves one wasted ssh round-trip on Ctrl+C
			// (review finding M1).
			if err := ctx.Err(); err != nil {
				return err
			}
			if err := runShellStep(ctx, steps[i].line, steps[i].name, logFile); err != nil {
				return fmt.Errorf("step %d/4 %s: %w", i+1, steps[i].name, err)
			}
			steps[i].done = true
		}
		return nil
	}
}

// runShellStep executes one `sh -c` invocation, optionally tee'ing
// combined output into the cluster log. A single failure causes the
// whole probe attempt to fail (the higher-level retry / concurrency
// loop handles recovery).
func runShellStep(ctx context.Context, line, label string, logFile *os.File) error {
	cmd := exec.CommandContext(ctx, "sh", "-c", line)
	out, err := cmd.CombinedOutput()
	if logFile != nil {
		ts := time.Now().UTC().Format("15:04:05")
		fmt.Fprintf(logFile, "[%s] === %s ===\n", ts, label)
		if len(out) > 0 {
			logFile.Write(out)
			if out[len(out)-1] != '\n' {
				fmt.Fprintln(logFile)
			}
		}
		if err != nil {
			fmt.Fprintf(logFile, "[%s] %s FAILED: %v\n", ts, label, err)
		} else {
			fmt.Fprintf(logFile, "[%s] %s OK\n", ts, label)
		}
	}
	return err
}
