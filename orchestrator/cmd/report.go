package cmd

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/report"
)

func newReportCmd() *cobra.Command {
	var (
		runID             string
		latest            bool
		input             string
		manifestPath      string
		combinedCSV       string
		outputPath        string
		title             string
		envLine           string
		logoPath          string
		howToRead         string
		unstableThreshold float64
	)

	cmd := &cobra.Command{
		Use:   "report",
		Short: "Render the canonical HTML report from cells.jsonl + manifest.json",
		Long: `report consumes the JSONL aggregate produced by 'bench run' /
'bench aggregate' and emits a self-contained HTML page with:

  - hero (title, run-id, mode, bench/source SHA, k6 image digest)
  - executive summary table sorted by avg RPS
  - peak-RSS chip grid
  - radar chart (relative RPS by policy, % of best)
  - one tab per policy with description + parity status line
    + 1..4 sub-sections per load profile (RPS chart, latency chart,
      detailed table) + EXCLUDED rows tail-listed
  - download buttons for manifest.json, matrix.csv, cells.jsonl, matrix.md

Inputs (pick one):

  --run-id <id>       reads reports/<id>/cells.jsonl + manifest.json
  --latest            picks the newest reports/<timestamp>/ directory
  --input <path>      explicit path to a cells.jsonl
  --combined a,b,c    merge multiple runs into one report

Output defaults to reports/<id>/report.html (next to the JSONL).`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if input == "" && runID == "" && combinedCSV == "" && !latest {
				return fmt.Errorf("one of --run-id, --latest, --input, or --combined is required")
			}
			if runID == "" && latest && input == "" && combinedCSV == "" {
				rid, err := pickLatestRun(flagRepoRoot)
				if err != nil {
					return err
				}
				runID = rid
				fmt.Fprintf(cmd.ErrOrStderr(), "report: latest run-id resolved → %s\n", runID)
			}
			if runID == "" && flagRunID != "" {
				runID = flagRunID
			}

			combined := splitCSV(combinedCSV)

			loaded, err := report.Load(report.LoadOptions{
				RepoRoot:       flagRepoRoot,
				RunID:          runID,
				CombinedRunIDs: combined,
				JSONLOverride:  input,
				ManifestPath:   manifestPath,
			})
			if err != nil {
				return err
			}

			out, err := report.Render(loaded, report.Options{
				Title:             title,
				EnvLine:           envLine,
				LogoPath:          logoPath,
				OutputPath:        outputPath,
				UnstableThreshold: unstableThreshold,
				HowToRead:         howToRead,
			})
			if err != nil {
				return err
			}
			// Prefer a repo-relative path so the line can be copy-
			// pasted into `open …` even when the repo root contains
			// spaces (e.g. "/…/LEGA GATEWAY/…"). Fall back to the
			// absolute path only when --output steered the file
			// outside the repo root.
			displayOut := out
			if rel, rerr := filepath.Rel(flagRepoRoot, out); rerr == nil && !strings.HasPrefix(rel, "..") {
				displayOut = rel
			}
			fmt.Fprintf(cmd.OutOrStdout(), "wrote %s (%d cells)\n", displayOut, len(loaded.Cells))
			return nil
		},
	}

	cmd.Flags().StringVar(&runID, "run-id", "", "single-run id (e.g. 20260423T120000Z)")
	cmd.Flags().BoolVar(&latest, "latest", false, "auto-pick the most recent timestamped run")
	cmd.Flags().StringVar(&input, "input", "", "explicit path to a cells.jsonl (bypasses --run-id)")
	cmd.Flags().StringVar(&manifestPath, "manifest", "",
		"explicit path to a manifest.json (used together with --input)")
	cmd.Flags().StringVar(&combinedCSV, "combined", "",
		"comma-separated list of run-ids to merge into one report")
	cmd.Flags().StringVar(&outputPath, "output", "",
		"override output path (default reports/<id>/report.html)")
	cmd.Flags().StringVar(&title, "title", "",
		"hero title (default: 'API Gateway Benchmark — <run-id>')")
	cmd.Flags().StringVar(&envLine, "env", "",
		"environment subtitle (default: derived from manifest.json)")
	cmd.Flags().StringVar(&logoPath, "logo", "",
		"path to a logo image embedded into the report hero")
	cmd.Flags().StringVar(&howToRead, "how-to-read", "",
		"override the explanatory note shown under the hero")
	cmd.Flags().Float64Var(&unstableThreshold, "unstable-threshold", 0.05,
		"flag a multi-rep cell as unstable when (max-min)/mean RPS spread exceeds this")

	return cmd
}

func splitCSV(csv string) []string {
	csv = strings.TrimSpace(csv)
	if csv == "" {
		return nil
	}
	parts := strings.Split(csv, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
