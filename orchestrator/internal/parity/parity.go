// Package parity wraps scripts/parity-attestation.sh — the bash
// driver that probes a running gateway against the per-policy
// fixture file (fixtures/<policy>.jsonl) and asserts that every
// expected status code / header transformation actually happens.
//
// The orchestrator runs parity BEFORE every cell so a misconfigured
// gateway is detected up-front, rather than after spending a full
// p2-sustained worth of bench time on something that never returned
// the expected verdict.
package parity

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Status is one of the four terminal verdicts emitted by the bash
// script. FEATURE_MISSING flags policies the gateway intentionally
// can't implement (e.g. Tyk body rewrites) — those cells are
// excluded from ranking, not failed.
type Status string

const (
	StatusPass            Status = "PASS"
	StatusFail            Status = "FAIL"
	StatusFeatureMissing  Status = "FEATURE_MISSING"
	StatusError           Status = "ERROR"
)

// Report mirrors the JSON parity-attestation.sh writes to
// <output_dir>/parity.json.
type Report struct {
	Status   Status `json:"status"`
	Gateway  string `json:"gateway"`
	Profile  string `json:"profile"`
	Target   string `json:"target,omitempty"`
	Reason   string `json:"reason,omitempty"`
	Duration float64 `json:"duration_sec,omitempty"`
}

// Checker holds the invariants shared across calls.
type Checker struct {
	RepoRoot string
	Target   string        // e.g. http://localhost:9080
	Backend  string        // optional --backend-peek URL
	Timeout  time.Duration // zero ≡ 90 s
	Logger   io.Writer     // defaults to os.Stderr
}

// Check runs parity for one (gateway, policy) pair and returns the
// parsed report. The caller decides whether to skip a cell on
// FAIL/FEATURE_MISSING.
//
// outputDir is the per-cell directory created by load-gateway.sh; we
// write parity.json inside it.
func (c *Checker) Check(ctx context.Context, gateway, policy, outputDir string) (Report, error) {
	if c.Logger == nil {
		c.Logger = os.Stderr
	}
	if c.Timeout == 0 {
		c.Timeout = 90 * time.Second
	}
	if outputDir == "" {
		return Report{}, fmt.Errorf("parity: outputDir is required")
	}
	cellDir := filepath.Join(c.RepoRoot, outputDir)
	if err := os.MkdirAll(cellDir, 0o755); err != nil {
		return Report{}, fmt.Errorf("parity: mkdir %s: %w", outputDir, err)
	}
	parityRel := filepath.Join(outputDir, "parity.json")

	args := []string{
		"scripts/parity-attestation.sh",
		"--gateway", gateway,
		"--profile", policy,
		"--output", parityRel,
	}
	if c.Target != "" {
		args = append(args, "--target", c.Target)
	}
	if c.Backend != "" {
		args = append(args, "--backend-peek", c.Backend)
	}

	runCtx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()

	cmd := exec.CommandContext(runCtx, "bash", args...)
	cmd.Dir = c.RepoRoot
	cmd.Env = os.Environ()
	cmd.Stdout = c.Logger
	cmd.Stderr = c.Logger

	err := cmd.Run()
	if runCtx.Err() == context.DeadlineExceeded {
		return Report{Status: StatusError, Reason: fmt.Sprintf("parity timeout after %s", c.Timeout)},
			fmt.Errorf("parity timeout")
	}

	parityAbs := filepath.Join(c.RepoRoot, parityRel)
	if data, readErr := os.ReadFile(parityAbs); readErr == nil {
		var rep Report
		if jerr := json.Unmarshal(data, &rep); jerr == nil {
			return rep, nil
		}
	}

	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return Report{
				Status: StatusFail,
				Reason: fmt.Sprintf("parity exit %d", ee.ExitCode()),
			}, nil
		}
		return Report{Status: StatusError, Reason: err.Error()}, err
	}
	return Report{Status: StatusPass}, nil
}

// Allowed reports whether a parity status should let the load run
// proceed. PASS continues; FAIL/ERROR mark the cell FAIL; FEATURE_MISSING
// excludes it cleanly.
func Allowed(s Status) bool { return s == StatusPass }
