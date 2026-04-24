package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/checkpoint"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/manifest"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/parity"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/report"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/runner"
)

func newRunCmd() *cobra.Command {
	var (
		gatewaysCSV        string
		policiesCSV        string
		scenariosCSV       string
		loadsCSV           string
		seed               int64
		repetitions        int
		mode               string
		dryRun             bool
		stopOnFail         bool
		stream             bool
		keepUp             bool
		watchdogMins       int
		retryOnCrash       int
		skipParity         bool
		gatewayTarget      string
		backendPeek        string
		notes              string
		resume             bool
		renderReport       bool
		disableNativeStats bool
	)

	cmd := &cobra.Command{
		Use:   "run",
		Short: "Run a (gateway × policy × scenario × load) sweep end-to-end",
		Long: `Run drives one or more cells through the canonical pipeline:

  parity-attestation.sh → load-gateway.sh → aggregate.

A reports/<run-id>/ directory is populated with:

  - manifest.json       — pinned source / image / seed metadata
  - matrix.csv          — wide table (27 columns)
  - cells.jsonl         — same data as JSONL with derived health column
  - matrix.md           — short markdown rollup
  - checkpoint.jsonl    — append-only resume log
  - raw/                — untouched per-cell artefacts

Use --dry-run first to see the planned cell list.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			if ctx == nil {
				ctx = context.Background()
			}

			gateways := resolveSelection("gateways", gatewaysCSV, matrix.CanonicalGateways)
			policies := resolveSelection("policies", policiesCSV, matrix.CanonicalPolicies)
			loads := resolveSelection("loads", loadsCSV, []string{"p1-baseline"})

			scenarios := matrix.ParseCSV(scenariosCSV)

			sel := matrix.Selection{
				Gateways:    gateways,
				Policies:    policies,
				Scenarios:   scenarios,
				Loads:       loads,
				Repetitions: repetitions,
			}
			cells, err := sel.Expand()
			if err != nil {
				return err
			}

			runID := flagRunID
			if runID == "" {
				runID = time.Now().UTC().Format("20060102T150405Z")
			}
			runDir := filepath.Join("reports", runID)

			if dryRun {
				fmt.Fprintf(cmd.OutOrStdout(), "=== bench run (dry-run) ===\n")
				fmt.Fprintf(cmd.OutOrStdout(), "  run-id:      %s\n", runID)
				fmt.Fprintf(cmd.OutOrStdout(), "  mode:        %s\n", mode)
				fmt.Fprintf(cmd.OutOrStdout(), "  total cells: %d\n", len(cells))
				for i, c := range cells {
					fmt.Fprintf(cmd.OutOrStdout(), "  %3d. %s\n", i+1, c.ID())
				}
				return nil
			}

			if err := os.MkdirAll(filepath.Join(flagRepoRoot, runDir), 0o755); err != nil {
				return fmt.Errorf("mkdir run dir: %w", err)
			}

			// -------------------------------------------------- manifest
			mb := manifest.New(ctx, flagRepoRoot, mode, runID, seed)
			mb.SetRepetitions(repetitions)
			mb.SetStopOnFail(stopOnFail)
			if notes != "" {
				mb.SetNotes(notes)
			}
			seenGateways := map[string]struct{}{}
			for _, c := range cells {
				if _, ok := seenGateways[c.Gateway]; !ok {
					mb.AddGateway(ctx, c.Gateway)
					seenGateways[c.Gateway] = struct{}{}
				}
				mb.AddRow(c.ID())
			}
			manifestPath := filepath.Join(flagRepoRoot, runDir, "manifest.json")
			if err := mb.Write(manifestPath); err != nil {
				return err
			}

			// -------------------------------------------------- checkpoint
			cpPath := filepath.Join(flagRepoRoot, runDir, "checkpoint.jsonl")
			cp, err := checkpoint.Open(cpPath)
			if err != nil {
				return err
			}
			defer cp.Close()
			if !resume {
				// when --resume is not set, refuse to silently skip cells that
				// already have checkpoint records — fail fast unless the operator
				// asked for it.
				if snap := cp.Snapshot(); len(snap) > 0 {
					fmt.Fprintf(cmd.ErrOrStderr(),
						"warning: existing checkpoint with %d cells found at %s; "+
							"pass --resume to skip them, otherwise they will be re-run.\n",
						len(snap), cpPath)
				}
			}

			// -------------------------------------------------- runners
			runr := &runner.Runner{
				RepoRoot:           flagRepoRoot,
				RunID:              runID,
				Seed:               seed,
				Stream:             stream,
				KeepUp:             keepUp,
				Watchdog:           time.Duration(watchdogMins) * time.Minute,
				RetryOnCrash:       retryOnCrash,
				DisableNativeStats: disableNativeStats,
				Logger:             cmd.OutOrStderr(),
			}
			parityChk := &parity.Checker{
				RepoRoot: flagRepoRoot,
				Target:   gatewayTarget,
				Backend:  backendPeek,
				Logger:   cmd.OutOrStderr(),
			}

			// -------------------------------------------------- sweep
			fmt.Fprintf(cmd.OutOrStdout(), "=== bench run ===\n")
			fmt.Fprintf(cmd.OutOrStdout(), "  run-id:    %s\n", runID)
			fmt.Fprintf(cmd.OutOrStdout(), "  mode:      %s\n", mode)
			fmt.Fprintf(cmd.OutOrStdout(), "  cells:     %d\n", len(cells))
			fmt.Fprintf(cmd.OutOrStdout(), "  reports:   %s/\n", runDir)

			var pass, excluded, failed, crashed, skipped int
			for i, cell := range cells {
				idx := fmt.Sprintf("[%d/%d]", i+1, len(cells))
				if resume {
					if v, done := cp.HasDone(cell.ID()); done {
						skipped++
						fmt.Fprintf(cmd.OutOrStdout(), "%s SKIP (resume) %s — was %s\n", idx, cell.ID(), v)
						continue
					}
				}

				// ---------- parity gate
				if !skipParity {
					rep, perr := parityChk.Check(ctx, cell.Gateway, cell.Policy, cell.OutputDir(runID))
					if perr != nil && rep.Status == "" {
						fmt.Fprintf(cmd.OutOrStdout(), "%s ERROR (parity) %s: %v\n", idx, cell.ID(), perr)
					}
					if !parity.Allowed(rep.Status) {
						verdict := runner.VerdictFail
						if rep.Status == parity.StatusFeatureMissing {
							verdict = runner.VerdictExcluded
							excluded++
						} else {
							failed++
						}
						res := runner.Result{
							Cell:      cell,
							Verdict:   verdict,
							OutputDir: cell.OutputDir(runID),
							Error:     fmt.Sprintf("parity %s: %s", rep.Status, rep.Reason),
							StartedAt: time.Now().UTC(),
							EndedAt:   time.Now().UTC(),
						}
						_ = cp.Append(res)
						fmt.Fprintf(cmd.OutOrStdout(), "%s %s (parity-gate) %s — %s\n",
							idx, verdict, cell.ID(), rep.Status)
						if stopOnFail && verdict == runner.VerdictFail {
							return fmt.Errorf("stop-on-fail: cell %s failed parity (%s)", cell.ID(), rep.Status)
						}
						continue
					}
				}

				// ---------- load
				res := runr.Run(ctx, cell)
				_ = cp.Append(res)

				switch res.Verdict {
				case runner.VerdictPass:
					pass++
				case runner.VerdictExcluded:
					excluded++
				case runner.VerdictCrashed:
					crashed++
				default:
					failed++
				}
				tries := ""
				if res.Attempts > 1 {
					tries = fmt.Sprintf(" [%d attempts]", res.Attempts)
				}
				fmt.Fprintf(cmd.OutOrStdout(), "%s %s %s (%.1fs)%s\n",
					idx, res.Verdict, cell.ID(), res.Duration, tries)

				if stopOnFail && (res.Verdict == runner.VerdictFail ||
					res.Verdict == runner.VerdictCrashed ||
					res.Verdict == runner.VerdictTimeout) {
					return fmt.Errorf("stop-on-fail: cell %s ended %s", cell.ID(), res.Verdict)
				}
			}

			// -------------------------------------------------- aggregate
			agg := &aggregate.Aggregator{RepoRoot: flagRepoRoot, RunID: runID}
			collected, aerr := agg.Collect()
			if aerr != nil {
				fmt.Fprintf(cmd.OutOrStdout(), "warning: aggregate skipped (%v)\n", aerr)
			} else {
				csvPath := filepath.Join(flagRepoRoot, runDir, "matrix.csv")
				jsonPath := filepath.Join(flagRepoRoot, runDir, "cells.jsonl")
				mdPath := filepath.Join(flagRepoRoot, runDir, "matrix.md")
				if err := agg.WriteCSV(csvPath, collected); err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "csv write failed: %v\n", err)
				}
				if err := agg.WriteJSONL(jsonPath, collected); err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "jsonl write failed: %v\n", err)
				}
				if err := agg.WriteMarkdown(mdPath, collected); err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "md write failed: %v\n", err)
				}
			}

			mb.Finalize()
			_ = mb.Write(manifestPath)

			if renderReport && aerr == nil {
				loaded, lerr := report.Load(report.LoadOptions{
					RepoRoot: flagRepoRoot,
					RunID:    runID,
				})
				if lerr != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "report skipped: %v\n", lerr)
				} else if out, rerr := report.Render(loaded, report.Options{}); rerr != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "report skipped: %v\n", rerr)
				} else {
					fmt.Fprintf(cmd.OutOrStdout(), "  report:   %s\n", out)
				}
			}

			fmt.Fprintln(cmd.OutOrStdout(), "")
			fmt.Fprintln(cmd.OutOrStdout(), "=== sweep complete ===")
			fmt.Fprintf(cmd.OutOrStdout(), "  PASS:     %d/%d\n", pass, len(cells))
			fmt.Fprintf(cmd.OutOrStdout(), "  EXCLUDED: %d/%d\n", excluded, len(cells))
			fmt.Fprintf(cmd.OutOrStdout(), "  FAIL:     %d/%d\n", failed, len(cells))
			if crashed > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "  CRASHED:  %d/%d\n", crashed, len(cells))
			}
			if skipped > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "  SKIPPED:  %d/%d (resume)\n", skipped, len(cells))
			}
			fmt.Fprintf(cmd.OutOrStdout(), "  manifest: %s\n", manifestPath)
			fmt.Fprintf(cmd.OutOrStdout(), "  reports:  %s/\n", runDir)

			if failed > 0 || crashed > 0 {
				return fmt.Errorf("sweep ended with %d failed cells", failed+crashed)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&gatewaysCSV, "gateways", "nginx",
		"comma-separated gateways or 'all' (default 'nginx')")
	cmd.Flags().StringVar(&policiesCSV, "policies", "p01-vanilla",
		"comma-separated policies or 'all'/'core'")
	cmd.Flags().StringVar(&scenariosCSV, "scenarios", "",
		"comma-separated scenarios; one-per-policy in order; auto-derived when empty")
	cmd.Flags().StringVar(&loadsCSV, "loads", "p1-baseline",
		"comma-separated load profiles or 'all'/'http'/'paced'")
	cmd.Flags().Int64Var(&seed, "seed", 42, "RNG seed (forwarded to k6 via BENCH_RUN_SEED)")
	cmd.Flags().IntVar(&repetitions, "reps", 1, "repetitions per cell")
	cmd.Flags().StringVar(&mode, "mode", "local", "infra mode: local | aws (annotation only)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the cell plan and exit")
	cmd.Flags().BoolVar(&stopOnFail, "stop-on-fail", false, "halt sweep on the first FAIL/CRASHED")
	cmd.Flags().BoolVar(&stream, "stream", false, "forward k6 per-request streaming JSON")
	cmd.Flags().BoolVar(&keepUp, "keep-up", false, "leave the gateway up between cells (debug)")
	cmd.Flags().IntVar(&watchdogMins, "watchdog-mins", 30,
		"per-cell watchdog timeout in minutes (0 to disable)")
	cmd.Flags().IntVar(&retryOnCrash, "retry-on-crash", 1,
		"re-run a cell up to N additional times if the gateway container "+
			"crashes mid-run (0 disables, 1 = retry once). FAIL and TIMEOUT are never retried.")
	cmd.Flags().BoolVar(&disableNativeStats, "disable-native-stats", false,
		"fall back to the shell docker-stats sidecar (scripts/docker-stats-sidecar.sh) "+
			"instead of the native Go collector. Default is the native collector.")
	cmd.Flags().BoolVar(&skipParity, "skip-parity", false,
		"skip parity-attestation.sh (NOT recommended; use only for debugging)")
	cmd.Flags().StringVar(&gatewayTarget, "target", "",
		"override gateway URL forwarded to parity-attestation.sh (e.g. http://localhost:9080)")
	cmd.Flags().StringVar(&backendPeek, "backend-peek", "",
		"backend URL passed to parity-attestation.sh --backend-peek")
	cmd.Flags().StringVar(&notes, "notes", "",
		"free-form notes stamped into manifest.json (e.g. 'AWS canonical run')")
	cmd.Flags().BoolVar(&resume, "resume", false,
		"skip cells already recorded in checkpoint.jsonl")
	cmd.Flags().BoolVar(&renderReport, "report", true,
		"render reports/<run-id>/report.html after the sweep (set false to skip)")

	return cmd
}

// resolveSelection turns a CSV string into a sorted, deduped slice,
// expanding the well-known aliases (all/core/http/paced).
func resolveSelection(kind, csv string, fallback []string) []string {
	csv = strings.TrimSpace(csv)
	if csv == "" {
		return append([]string(nil), fallback...)
	}
	if alias := matrix.ResolveAlias(kind, csv); alias != nil {
		return matrix.SortStable(kind, alias)
	}
	return matrix.SortStable(kind, matrix.ParseCSV(csv))
}
