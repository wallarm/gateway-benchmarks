package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/readiness"
)

// awsReadinessInput is the JSON shape consumed on stdin. Mirrors the
// fields surfaced by `tofu output -json cluster_shards` plus a single
// extra `ssh_options` string the caller wants spliced into every ssh
// invocation (StrictHostKeyChecking=no etc — the same options the
// bash `ssh_opts()` function used to inject via sed).
type awsReadinessInput struct {
	SSHOptions string                `json:"ssh_options"`
	Clusters   []awsReadinessCluster `json:"clusters"`
}

type awsReadinessCluster struct {
	Index      int    `json:"index"`
	LoadgenSSH string `json:"loadgen_ssh"`
	GatewaySSH string `json:"gateway_ssh"`
	BackendSSH string `json:"backend_ssh"`
}

func newAWSReadinessCmd() *cobra.Command {
	var (
		timeout      time.Duration
		pollInterval time.Duration
		logPath      string
	)

	cmd := &cobra.Command{
		Use:   "aws-readiness",
		Short: "Wait for cloud-init + Docker on every AWS cluster in parallel",
		Long: "aws-readiness consumes a JSON cluster description on stdin and\n" +
			"runs a docker-info readiness probe against every (loadgen, gateway,\n" +
			"backend) host concurrently. It replaces the nested for-loop in\n" +
			"scripts/perf-aws-full-report.sh whose sequential per-host wait\n" +
			"inflated fleet-readiness time from ~1 minute to ~30 minutes on a\n" +
			"22-cluster sweep.\n\n" +
			"Input shape (stdin):\n" +
			"  {\n" +
			"    \"ssh_options\": \"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ...\",\n" +
			"    \"clusters\": [\n" +
			"      {\n" +
			"        \"index\":       0,\n" +
			"        \"loadgen_ssh\": \"ssh -i ~/.ssh/key ubuntu@10.0.0.1\",\n" +
			"        \"gateway_ssh\": \"ssh -i ~/.ssh/key ubuntu@10.0.0.2\",\n" +
			"        \"backend_ssh\": \"ssh -i ~/.ssh/key ubuntu@10.0.0.3\"\n" +
			"      }\n" +
			"    ]\n" +
			"  }\n\n" +
			"The probe is `docker info` for loadgen + gateway, and\n" +
			"`docker info && curl http://127.0.0.1:8080/status/200` for the\n" +
			"backend (which must already be serving the bench backend image\n" +
			"before the matrix run can start).\n\n" +
			"Exit 0 = every host became ready inside --timeout.\n" +
			"Exit 1 = at least one host stayed down.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runAWSReadiness(cmd.Context(), os.Stdin, os.Stderr, timeout, pollInterval, logPath)
		},
	}

	cmd.Flags().DurationVar(&timeout, "timeout", 15*time.Minute,
		"per-host readiness budget; the fleet wait gives up once any host exceeds this")
	cmd.Flags().DurationVar(&pollInterval, "poll-interval", 10*time.Second,
		"sleep between consecutive attempts on the same host")
	cmd.Flags().StringVar(&logPath, "log", "",
		"append per-attempt SSH output to this file (default: dropped)")

	return cmd
}

func runAWSReadiness(
	ctx context.Context,
	stdin io.Reader,
	progressOut io.Writer,
	timeout, pollInterval time.Duration,
	logPath string,
) error {
	raw, err := io.ReadAll(stdin)
	if err != nil {
		return fmt.Errorf("read stdin: %w", err)
	}
	var input awsReadinessInput
	if err := json.Unmarshal(raw, &input); err != nil {
		return fmt.Errorf("parse readiness input JSON: %w", err)
	}
	if len(input.Clusters) == 0 {
		return fmt.Errorf("readiness input contains zero clusters")
	}

	var logFile *os.File
	if logPath != "" {
		logFile, err = os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err != nil {
			return fmt.Errorf("open log %q: %w", logPath, err)
		}
		defer logFile.Close()
	}

	// Validate every ssh-line up front so a tofu output drift fails
	// the run synchronously before we open log files or spawn
	// goroutines (review finding H3).
	allLines := make([]string, 0, len(input.Clusters)*3)
	for _, c := range input.Clusters {
		allLines = append(allLines, c.LoadgenSSH, c.GatewaySSH, c.BackendSSH)
	}
	if err := validateSSHLines(allLines, input.SSHOptions); err != nil {
		return fmt.Errorf("ssh-line validation: %w", err)
	}

	const (
		dockerProbe  = "docker info >/dev/null 2>&1"
		backendProbe = "docker info >/dev/null 2>&1 && curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/status/200"
	)
	probes := make([]readiness.Probe, 0, len(input.Clusters)*3)
	for _, c := range input.Clusters {
		hostList := []struct {
			role   string
			sshCmd string
			check  string
		}{
			{"loadgen", c.LoadgenSSH, dockerProbe},
			{"gateway", c.GatewaySSH, dockerProbe},
			{"backend", c.BackendSSH, backendProbe},
		}
		for _, h := range hostList {
			label := fmt.Sprintf("cluster %d %s", c.Index, h.role)
			// Safe to ignore error: validateSSHLines above already
			// confirmed every line passes the same check.
			sshLine, _ := injectSSHOptions(h.sshCmd, input.SSHOptions)
			probes = append(probes, readiness.Probe{
				Label: label,
				Run:   newSubprocessProbe(sshLine, h.check, logFile, label),
			})
		}
	}

	fmt.Fprintf(progressOut, "▶ Waiting for %d hosts (timeout %s, poll %s)\n",
		len(probes), timeout, pollInterval)

	cfg := readiness.Config{
		PollInterval: pollInterval,
		Timeout:      timeout,
		// Tick every 10s — frequent enough to feel live, sparse enough
		// to keep stderr readable on a slow terminal.
		ProgressEvery: 10 * time.Second,
		Progress: func(s readiness.Snapshot) {
			fmt.Fprintf(progressOut, "  [%s] %d/%d ready · %d waiting · %d failed\n",
				fmtDuration(s.Elapsed), s.Ready, s.Total, s.Waiting, s.Failed)
		},
	}

	results, waitErr := readiness.Wait(ctx, probes, cfg)

	// Per-host outcome summary — one line each, in input order so it
	// reads as a natural cluster-major table.
	for _, r := range results {
		if r.Ready {
			fmt.Fprintf(progressOut, "  ✓ %s — ready (%d attempts, %s)\n",
				r.Label, r.Attempts, fmtDuration(r.Duration))
			continue
		}
		fmt.Fprintf(progressOut, "  ✗ %s — FAILED after %d attempts (%s): %v\n",
			r.Label, r.Attempts, fmtDuration(r.Duration), r.LastErr)
	}

	if waitErr != nil {
		return waitErr
	}
	fmt.Fprintln(progressOut, "✓ All hosts ready")
	return nil
}

// injectSSHOptions splices a list of -o options between "ssh " and the
// rest of the original command. Same effect as the previous bash
// `ssh_opts()` sed-rewrite: the caller passes an unmodified
// "ssh -i key user@host" line and the operational hardening
// (StrictHostKeyChecking, ConnectTimeout, ServerAliveInterval, ...)
// is bolted on here from a single source of truth.
//
// Returns an error when the line does NOT begin with the literal
// "ssh " prefix. The earlier silent-pass-through behaviour was a
// foot-gun (review finding H3): a future tofu output that wraps the
// command in env vars or uses an absolute `/usr/bin/ssh` would skip
// every SSH hardening flag and the probe would hang forever waiting
// for a password prompt instead of failing fast. We'd rather refuse
// to run than start an unhardened ssh.
func injectSSHOptions(sshLine, options string) (string, error) {
	const prefix = "ssh "
	if !strings.HasPrefix(sshLine, prefix) {
		return "", fmt.Errorf("ssh command must start with %q, got %q "+
			"(silent pass-through would skip ConnectTimeout/BatchMode "+
			"and the probe would hang on a password prompt)", prefix, sshLine)
	}
	if options == "" {
		return sshLine, nil
	}
	return prefix + options + " " + sshLine[len(prefix):], nil
}

// validateSSHLines checks every supplied ssh-line up front so the
// caller can fail before launching N probe goroutines. Returns the
// first offender encountered.
func validateSSHLines(lines []string, options string) error {
	for _, l := range lines {
		if _, err := injectSSHOptions(l, options); err != nil {
			return err
		}
	}
	return nil
}

// newSubprocessProbe wires Probe.Run to `sh -c "<sshLine> '<check>'"`.
// Using sh -c keeps the existing operator mental model — the probe is
// literally what they would type at a shell — and means we don't need
// a native Go SSH client just to run docker-info. CombinedOutput is
// echoed to logFile so a stuck cell can be diagnosed post-mortem.
func newSubprocessProbe(sshLine, check string, logFile *os.File, label string) func(ctx context.Context) error {
	return func(ctx context.Context) error {
		full := sshLine + " " + shellQuote(check)
		cmd := exec.CommandContext(ctx, "sh", "-c", full)
		out, err := cmd.CombinedOutput()
		if logFile != nil {
			ts := time.Now().UTC().Format("15:04:05")
			if err == nil {
				fmt.Fprintf(logFile, "[%s] %s: ready\n", ts, label)
			} else {
				fmt.Fprintf(logFile, "[%s] %s: attempt failed: %v\n%s",
					ts, label, err, string(out))
			}
		}
		return err
	}
}

// shellQuote wraps a string in single quotes for safe sh -c expansion.
// The replacement of `'` with `'\”` is the canonical sh-quoting trick:
// close the quote, escape one literal `'`, reopen the quote.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func fmtDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
}
