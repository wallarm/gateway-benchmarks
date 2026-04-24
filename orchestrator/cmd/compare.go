package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/compare"
)

// newCompareCmd wires `bench compare-runs A B`. The two arguments
// are run IDs resolved under $repo/reports/<id>/; --input-a /
// --input-b let callers point at an explicit cells.jsonl path
// instead (useful for re-rendered / stitched reports).
//
// Exit codes (TASK §8, REPRODUCIBILITY.md):
//
//	0 — REPRODUCIBLE (identity + tolerance + rank all pass)
//	1 — soft diff (only-in-A / only-in-B cells, matrix shape changed)
//	2 — NOT REPRODUCIBLE (identity mismatch, metric outside tolerance,
//	    or top-3 rank unstable)
func newCompareCmd() *cobra.Command {
	var (
		inputA, inputB       string
		manifestA, manifestB string
		labelA, labelB       string
		jsonOut              bool
		rpsTol               float64
		latTol               float64
		memTol               float64
		cpuTol               float64
		errorsMustEq         bool
	)

	cmd := &cobra.Command{
		Use:   "compare-runs <run-id-a> <run-id-b>",
		Short: "Diff two bench runs against the canonical tolerance table",
		Long: `compare-runs answers the Phase 8 reproducibility question:
"given two sweeps on the same SHA, do they produce the same ranking
within tolerance?" It reads cells.jsonl + manifest.json for both
sides and reports:

  1. identity    — git_sha, seed, k6_digest, selected_rows, per-
                   gateway image digests (skipped if manifests are
                   absent)
  2. tolerance   — per-cell RPS, p50/p95/p99, mem peak/steady,
                   CPU %, and hard-equality on 5xx / 4xx_expected
  3. rank        — top-3 gateways per (policy, load, scenario) column

Default tolerances match docs/REPRODUCIBILITY.md §Tolerances
(TASK §8); override with --rps / --latency / --mem / --cpu.

Exit codes: 0 reproducible · 1 soft diff · 2 NOT reproducible.`,
		Args: cobra.MaximumNArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			var runA, runB string
			if len(args) >= 1 {
				runA = args[0]
			}
			if len(args) >= 2 {
				runB = args[1]
			}
			if inputA == "" && runA == "" {
				return fmt.Errorf("first run id (or --input-a) is required")
			}
			if inputB == "" && runB == "" {
				return fmt.Errorf("second run id (or --input-b) is required")
			}

			if labelA == "" {
				labelA = firstNonEmptyCmd(runA, inputA, "run-A")
			}
			if labelB == "" {
				labelB = firstNonEmptyCmd(runB, inputB, "run-B")
			}

			a, err := compare.Load(compare.LoadOptions{
				RepoRoot:     flagRepoRoot,
				RunID:        runA,
				JSONLPath:    inputA,
				ManifestPath: manifestA,
				Label:        labelA,
				AllowMissing: true,
			})
			if err != nil {
				return fmt.Errorf("load A: %w", err)
			}
			b, err := compare.Load(compare.LoadOptions{
				RepoRoot:     flagRepoRoot,
				RunID:        runB,
				JSONLPath:    inputB,
				ManifestPath: manifestB,
				Label:        labelB,
				AllowMissing: true,
			})
			if err != nil {
				return fmt.Errorf("load B: %w", err)
			}

			tol := compare.DefaultTolerances()
			if cmd.Flags().Changed("rps") {
				tol.RPS = rpsTol
			}
			if cmd.Flags().Changed("latency") {
				tol.LatencyP50 = latTol
				tol.LatencyP95 = latTol
				tol.LatencyP99 = latTol
			}
			if cmd.Flags().Changed("mem") {
				tol.MemPeak = memTol
				tol.MemSteady = memTol
			}
			if cmd.Flags().Changed("cpu") {
				tol.CPUPct = cpuTol
			}
			if cmd.Flags().Changed("errors-strict") {
				tol.ErrorsMustEq = errorsMustEq
			}

			s := compare.Compare(a, b, tol)

			if jsonOut {
				enc := json.NewEncoder(cmd.OutOrStdout())
				enc.SetIndent("", "  ")
				if err := enc.Encode(s); err != nil {
					return err
				}
			} else {
				fmt.Fprint(cmd.OutOrStdout(), compare.RenderText(s, a.Label, b.Label))
			}

			os.Exit(s.ExitCode())
			return nil
		},
	}

	cmd.Flags().StringVar(&inputA, "input-a", "", "explicit cells.jsonl path for run A (overrides run-id)")
	cmd.Flags().StringVar(&inputB, "input-b", "", "explicit cells.jsonl path for run B (overrides run-id)")
	cmd.Flags().StringVar(&manifestA, "manifest-a", "", "explicit manifest.json path for run A")
	cmd.Flags().StringVar(&manifestB, "manifest-b", "", "explicit manifest.json path for run B")
	cmd.Flags().StringVar(&labelA, "label-a", "", "label printed for run A (defaults to run id)")
	cmd.Flags().StringVar(&labelB, "label-b", "", "label printed for run B (defaults to run id)")
	cmd.Flags().BoolVar(&jsonOut, "json", false, "emit the Summary as JSON instead of the human report")
	cmd.Flags().Float64Var(&rpsTol, "rps", 0.03, "fractional tolerance for RPS (default 0.03 = ±3%)")
	cmd.Flags().Float64Var(&latTol, "latency", 0.10, "fractional tolerance for p50/p95/p99 latency")
	cmd.Flags().Float64Var(&memTol, "mem", 0.05, "fractional tolerance for memory peak/steady")
	cmd.Flags().Float64Var(&cpuTol, "cpu", 0.10, "fractional tolerance for CPU %")
	cmd.Flags().BoolVar(&errorsMustEq, "errors-strict", true, "require 5xx + 4xx_expected counts to match exactly")

	return cmd
}

func firstNonEmptyCmd(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
