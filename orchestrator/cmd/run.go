package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
		matrixMode         string
		shardIndex         int
		shardCount         int
		seed               int64
		repetitions        int
		mode               string
		dryRun             bool
		parallelism        int
		stopOnFail         bool
		allowFailedCells   bool
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
		showProgress       bool
		progressInterval   time.Duration
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

			var cells []matrix.Cell
			var err error
			switch matrixMode {
			case "selection":
				sel := matrix.Selection{
					Gateways:    gateways,
					Policies:    policies,
					Scenarios:   scenarios,
					Loads:       loads,
					Repetitions: repetitions,
				}
				cells, err = sel.Expand()
			case "canonical":
				if len(scenarios) > 0 || cmd.Flags().Changed("policies") {
					return fmt.Errorf("--matrix canonical owns policies/scenarios; use --gateways/--loads/--reps to narrow it")
				}
				cells, err = matrix.CanonicalReportCells(gateways, loads, repetitions)
			default:
				return fmt.Errorf("unknown --matrix %q (valid: selection, canonical)", matrixMode)
			}
			if err != nil {
				return err
			}
			if shardCount < 1 {
				return fmt.Errorf("--shard-count must be >= 1")
			}
			if shardIndex < 0 || shardIndex >= shardCount {
				return fmt.Errorf("--shard-index must be in [0, %d), got %d", shardCount, shardIndex)
			}
			if shardCount > 1 {
				sharded := make([]matrix.Cell, 0, (len(cells)+shardCount-1)/shardCount)
				for i, cell := range cells {
					if i%shardCount == shardIndex {
						sharded = append(sharded, cell)
					}
				}
				cells = sharded
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
				if shardCount > 1 {
					fmt.Fprintf(cmd.OutOrStdout(), "  shard:       %d/%d\n", shardIndex+1, shardCount)
				}
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
			if parallelism < 1 {
				parallelism = 1
			}
			newRunner := func(cellEnv func(matrix.Cell) []string) *runner.Runner {
				return &runner.Runner{
					RepoRoot:           flagRepoRoot,
					RunID:              runID,
					Seed:               seed,
					Stream:             stream,
					KeepUp:             keepUp,
					Watchdog:           time.Duration(watchdogMins) * time.Minute,
					RetryOnCrash:       retryOnCrash,
					DisableNativeStats: disableNativeStats,
					Logger:             cmd.OutOrStderr(),
					Verbose:            flagVerbose,
					CellEnv:            cellEnv,
				}
			}
			parityChk := &parity.Checker{
				RepoRoot: flagRepoRoot,
				Target:   gatewayTarget,
				Backend:  backendPeek,
				Logger:   cmd.OutOrStderr(),
				Verbose:  flagVerbose,
			}

			// In local mode the per-cell stack is booted by
			// scripts/load-gateway.sh (runner.Run), so nothing listens
			// on --target before that script runs. Running parity here
			// would always fail with connection-refused. load-gateway.sh
			// invokes parity-attestation.sh itself once the stack is up
			// (scripts/load-gateway.sh §4 "parity precondition") and
			// writes the same parity.json artefact the aggregator reads,
			// so the external gate is both redundant and broken in local
			// mode — turn it off automatically. AWS mode keeps the gate
			// because the 3-host cluster is already up when `bench run`
			// starts. --skip-parity remains as an explicit escape hatch
			// for AWS debugging.
			parityAutoSkipped := false
			if (mode == "local" || parallelism > 1) && !skipParity {
				skipParity = true
				parityAutoSkipped = true
			}

			// -------------------------------------------------- sweep
			fmt.Fprintf(cmd.OutOrStdout(), "=== bench run ===\n")
			fmt.Fprintf(cmd.OutOrStdout(), "  run-id:    %s\n", runID)
			fmt.Fprintf(cmd.OutOrStdout(), "  mode:      %s\n", mode)
			if shardCount > 1 {
				fmt.Fprintf(cmd.OutOrStdout(), "  shard:     %d/%d\n", shardIndex+1, shardCount)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "  cells:     %d\n", len(cells))
			fmt.Fprintf(cmd.OutOrStdout(), "  parallel:  %d\n", parallelism)
			if gatewayTarget != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "  target:    %s\n", gatewayTarget)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "  reports:   %s/\n", runDir)
			if parityAutoSkipped {
				fmt.Fprintf(cmd.OutOrStdout(),
					"  parity:    delegated to load-gateway.sh (auto in local/parallel mode)\n")
			}

			var progress *progressTracker
			if showProgress && !flagQuiet {
				progress = newProgressTracker(cmd.OutOrStdout(), cells, progressInterval)
				progress.PrintPlan()
			}

			var (
				pass, excluded, failed, crashed, skipped int
				countsMu                                 sync.Mutex
			)
			addVerdict := func(v runner.Verdict) {
				countsMu.Lock()
				defer countsMu.Unlock()
				switch v {
				case runner.VerdictPass:
					pass++
				case runner.VerdictExcluded:
					excluded++
				case runner.VerdictCrashed:
					crashed++
				default:
					failed++
				}
			}
			addSkipped := func() {
				countsMu.Lock()
				skipped++
				countsMu.Unlock()
			}
			runCell := func(i int, cell matrix.Cell, runr *runner.Runner) error {
				idx := fmt.Sprintf("[%d/%d]", i+1, len(cells))
				if !flagQuiet {
					fmt.Fprintln(cmd.OutOrStdout(), "")
					fmt.Fprintf(cmd.OutOrStdout(), "%s %s\n", idx, formatCellLabel(cell))
				}
				if resume {
					if v, done := cp.HasDone(cell.ID()); done {
						addSkipped()
						if flagQuiet {
							fmt.Fprintf(cmd.OutOrStdout(), "%s SKIP %s — resume (%s)\n", idx, formatCellLabel(cell), v)
						} else {
							fmt.Fprintf(cmd.OutOrStdout(), "  resume: skipped — already recorded as %s\n", v)
						}
						return nil
					}
				}
				var stopProgress func()
				cellStarted := time.Now()
				if progress != nil {
					stopProgress = progress.StartCell(i, cell)
				}

				// ---------- parity gate
				if !skipParity {
					if !flagQuiet {
						fmt.Fprintf(cmd.OutOrStdout(), "  parity:  checking gateway behavior\n")
					}
					rep, perr := parityChk.Check(ctx, cell.Gateway, cell.Policy, cell.OutputDir(runID))
					if perr != nil && rep.Status == "" {
						if flagQuiet {
							fmt.Fprintf(cmd.OutOrStdout(), "%s ERROR %s — parity: %v\n", idx, formatCellLabel(cell), perr)
						} else {
							fmt.Fprintf(cmd.OutOrStdout(), "  parity:  ERROR — %v\n", perr)
						}
					}
					if !flagQuiet {
						fmt.Fprintf(cmd.OutOrStdout(), "  parity:  %s\n", formatParitySummary(rep))
					}
					if !parity.Allowed(rep.Status) {
						verdict := runner.VerdictFail
						if rep.Status == parity.StatusFeatureMissing {
							verdict = runner.VerdictExcluded
						}
						addVerdict(verdict)
						res := runner.Result{
							Cell:      cell,
							Verdict:   verdict,
							OutputDir: cell.OutputDir(runID),
							Error:     fmt.Sprintf("parity %s: %s", rep.Status, rep.Reason),
							StartedAt: time.Now().UTC(),
							EndedAt:   time.Now().UTC(),
						}
						_ = cp.Append(res)
						if stopProgress != nil {
							stopProgress()
							progress.FinishCell(i, cell, time.Since(cellStarted), string(verdict))
						}
						if flagQuiet {
							fmt.Fprintf(cmd.OutOrStdout(), "%s %s %s — parity gate (%s)\n",
								idx, verdict, formatCellLabel(cell), rep.Status)
						} else {
							fmt.Fprintf(cmd.OutOrStdout(), "  load:    skipped — blocked by parity gate\n")
							fmt.Fprintf(cmd.OutOrStdout(), "  file:    %s\n", filepath.Join(cell.OutputDir(runID), "parity.json"))
						}
						if stopOnFail && verdict == runner.VerdictFail {
							return fmt.Errorf("stop-on-fail: cell %s failed parity (%s)", cell.ID(), rep.Status)
						}
						return nil
					}
				} else if !flagQuiet {
					fmt.Fprintf(cmd.OutOrStdout(), "  parity:  skipped (--skip-parity)\n")
				}

				// ---------- load
				if !flagQuiet {
					fmt.Fprintf(cmd.OutOrStdout(), "  load:    running %s with %s\n", cell.Scenario, cell.Load)
				}
				res := runr.Run(ctx, cell)
				_ = cp.Append(res)
				if stopProgress != nil {
					stopProgress()
					progress.FinishCell(i, cell, time.Since(cellStarted), string(res.Verdict))
				}

				addVerdict(res.Verdict)
				if flagQuiet {
					tries := ""
					if res.Attempts > 1 {
						tries = fmt.Sprintf(" [%d attempts]", res.Attempts)
					}
					fmt.Fprintf(cmd.OutOrStdout(), "%s %s %s (%.1fs)%s\n",
						idx, res.Verdict, formatCellLabel(cell), res.Duration, tries)
				} else {
					fmt.Fprintf(cmd.OutOrStdout(), "  load:    %s\n", formatRunnerSummary(res))
					if res.Verdict != runner.VerdictPass {
						fmt.Fprintf(cmd.OutOrStdout(), "  logs:    %s\n", filepath.Join(cell.OutputDir(runID), "logs"))
					}
				}

				if stopOnFail && (res.Verdict == runner.VerdictFail ||
					res.Verdict == runner.VerdictCrashed ||
					res.Verdict == runner.VerdictTimeout) {
					return fmt.Errorf("stop-on-fail: cell %s ended %s", cell.ID(), res.Verdict)
				}
				return nil
			}
			if parallelism == 1 {
				runr := newRunner(nil)
				for i, cell := range cells {
					if err := runCell(i, cell, runr); err != nil {
						return err
					}
				}
			} else {
				if stopOnFail {
					return fmt.Errorf("--stop-on-fail is not supported with --parallel > 1")
				}
				type job struct {
					index int
					cell  matrix.Cell
				}
				jobs := make(chan job)
				errCh := make(chan error, parallelism)
				var wg sync.WaitGroup
				for worker := 0; worker < parallelism; worker++ {
					slot := worker
					runr := newRunner(parallelCellEnv(runID, slot))
					wg.Add(1)
					go func() {
						defer wg.Done()
						for j := range jobs {
							if err := runCell(j.index, j.cell, runr); err != nil {
								errCh <- err
							}
						}
					}()
				}
				for i, cell := range cells {
					jobs <- job{index: i, cell: cell}
				}
				close(jobs)
				wg.Wait()
				close(errCh)
				for err := range errCh {
					if err != nil {
						return err
					}
				}
			}

			// -------------------------------------------------- aggregate
			if !flagQuiet {
				fmt.Fprintln(cmd.OutOrStdout(), "")
				fmt.Fprintln(cmd.OutOrStdout(), "=== aggregate ===")
			}
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
				if !flagQuiet {
					fmt.Fprintf(cmd.OutOrStdout(), "  matrix:   %s\n", filepath.Join(runDir, "matrix.csv"))
					fmt.Fprintf(cmd.OutOrStdout(), "  cells:    %s\n", filepath.Join(runDir, "cells.jsonl"))
					fmt.Fprintf(cmd.OutOrStdout(), "  summary:  %s\n", filepath.Join(runDir, "matrix.md"))
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
					if !flagQuiet {
						// Keep the path consistent with the aggregate
						// block above (matrix/cells/summary are all
						// printed relative to the repo root). Rendering
						// returns an absolute path, which breaks
						// copy-paste into `open …` when the repo root
						// contains spaces. Fall back to the absolute
						// path only if --output steered the file
						// outside the repo root.
						displayOut := out
						if rel, rerr := filepath.Rel(flagRepoRoot, out); rerr == nil && !strings.HasPrefix(rel, "..") {
							displayOut = rel
						}
						fmt.Fprintf(cmd.OutOrStdout(), "  report:   %s\n", displayOut)
					}
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

			if (failed > 0 || crashed > 0) && !allowFailedCells {
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
	cmd.Flags().StringVar(&matrixMode, "matrix", "selection",
		"matrix expansion mode: selection (explicit policies/scenarios) or canonical (published report matrix)")
	cmd.Flags().IntVar(&shardIndex, "shard-index", 0,
		"zero-based shard index for fleet runs")
	cmd.Flags().IntVar(&shardCount, "shard-count", 1,
		"total shard count for fleet runs")
	cmd.Flags().Int64Var(&seed, "seed", 42, "RNG seed (forwarded to k6 via BENCH_RUN_SEED)")
	cmd.Flags().IntVar(&repetitions, "reps", 1, "repetitions per cell")
	cmd.Flags().StringVar(&mode, "mode", "local", "infra mode: local | aws (annotation only)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print the cell plan and exit")
	cmd.Flags().IntVar(&parallelism, "parallel", 1,
		"number of cells to run concurrently; >1 allocates isolated compose projects and host ports")
	cmd.Flags().BoolVar(&stopOnFail, "stop-on-fail", false, "halt sweep on the first FAIL/CRASHED")
	cmd.Flags().BoolVar(&allowFailedCells, "allow-failed-cells", false,
		"exit 0 after rendering the report even if some cells failed or crashed")
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
		"skip the pre-load parity-attestation.sh gate. Auto-enabled in "+
			"--mode local (load-gateway.sh runs parity itself once the "+
			"per-cell stack is up). In --mode aws the gate is on by default "+
			"and skipping is NOT recommended — use only for debugging.")
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
	cmd.Flags().BoolVar(&showProgress, "progress", true,
		"print progress bar, elapsed time, and ETA while the sweep runs")
	cmd.Flags().DurationVar(&progressInterval, "progress-interval", 30*time.Second,
		"how often to print in-flight progress updates")

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

func formatCellLabel(cell matrix.Cell) string {
	label := fmt.Sprintf("%s | %s | %s | %s", cell.Gateway, cell.Policy, cell.Scenario, cell.Load)
	if cell.Repetition > 1 {
		label += fmt.Sprintf(" | rep %d", cell.Repetition)
	}
	return label
}

func formatParitySummary(rep parity.Report) string {
	if rep.Status == "" {
		if rep.Reason != "" {
			return "ERROR — " + rep.Reason
		}
		return "ERROR"
	}
	parts := []string{string(rep.Status)}
	if rep.Probes > 0 {
		parts = append(parts, fmt.Sprintf("%d/%d probes", rep.Passed, rep.Probes))
	}
	if rep.Skipped > 0 {
		parts = append(parts, fmt.Sprintf("skipped %d", rep.Skipped))
	}
	if rep.Reason != "" && rep.Status != parity.StatusPass {
		parts = append(parts, rep.Reason)
	}
	return strings.Join(parts, " — ")
}

func formatRunnerSummary(res runner.Result) string {
	summary := string(res.Verdict)
	if res.Duration > 0 {
		summary += fmt.Sprintf(" in %.1fs", res.Duration)
	}
	if res.Attempts > 1 {
		summary += fmt.Sprintf(" (%d attempts)", res.Attempts)
	}
	if res.Error != "" && res.Verdict != runner.VerdictPass {
		summary += " — " + res.Error
	}
	return summary
}

func parallelCellEnv(runID string, slot int) func(matrix.Cell) []string {
	runSlug := sanitizeDockerName(runID)
	if runSlug == "" {
		runSlug = "run"
	}
	project := fmt.Sprintf("gwb-%s-w%02d", runSlug, slot+1)
	basePort := 20000 + slot*10
	return func(cell matrix.Cell) []string {
		prefix := fmt.Sprintf("%s-%s", project, sanitizeDockerName(cell.Gateway))
		return []string{
			"BENCH_COMPOSE_PROJECT=" + project,
			"BENCH_CONTAINER_PREFIX=" + prefix,
			fmt.Sprintf("GATEWAY_HTTP_PORT=%d", basePort),
			fmt.Sprintf("GATEWAY_HTTPS_PORT=%d", basePort+1),
			fmt.Sprintf("GATEWAY_ADMIN_PORT=%d", basePort+2),
			fmt.Sprintf("GATEWAY_ENVOY_ADMIN_PORT=%d", basePort+3),
		}
	}
}

func sanitizeDockerName(s string) string {
	s = strings.ToLower(s)
	var b strings.Builder
	lastDash := false
	for _, r := range s {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		if ok {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}
