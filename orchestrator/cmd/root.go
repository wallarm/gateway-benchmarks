// Package cmd wires the cobra commands. main.go is a 4-line stub
// that calls Execute(); every subcommand lives in its own file
// (run.go, validate.go, aggregate.go, manifest.go).
package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/version"
)

var (
	flagRepoRoot string
	flagRunID    string
	flagVerbose  bool
	flagQuiet    bool
)

// rootCmd is the top-level `bench` binary.
var rootCmd = &cobra.Command{
	Use:           "bench",
	Short:         "Reproducible API gateway benchmark orchestrator",
	SilenceUsage:  true,
	SilenceErrors: true,
	Long: `bench drives the (gateway × policy × scenario × load) matrix end-to-end:

  1. Builds a manifest stamped with the source revision, image digests,
     k6 version and host info.
  2. For every cell it runs scripts/parity-attestation.sh first; cells
     that don't pass parity are excluded or failed without burning load
     budget.
  3. For passing cells it invokes scripts/load-gateway.sh, captures
     k6-summary.json, docker-stats.csv and any sidecars.
  4. After the sweep it aggregates everything into reports/<RUN_ID>/
     {manifest.json, matrix.csv, cells.jsonl, matrix.md} and renders
     report.html via the native 'bench report' subcommand.
  5. 'bench compare-runs' (Phase 8) diffs any two sweeps against the
     canonical tolerance table and confirms top-3 rank stability.`,
	Version: version.Short(),
}

// Execute is the entry point invoked by main.go.
func Execute() error {
	rootCmd.SetVersionTemplate("{{.Use}} {{.Version}}\n")
	return rootCmd.Execute()
}

func init() {
	cwd, err := os.Getwd()
	if err != nil {
		cwd = "."
	}
	defaultRoot, _ := filepath.Abs(cwd)

	rootCmd.PersistentFlags().StringVar(&flagRepoRoot, "repo-root", defaultRoot,
		"absolute path to the gateway-benchmarks repo root (where scripts/ and gateways/ live)")
	rootCmd.PersistentFlags().StringVar(&flagRunID, "run-id", "",
		"override the timestamp-based run id (e.g. 20260423T120000Z); auto-generated if empty")
	rootCmd.PersistentFlags().BoolVarP(&flagVerbose, "verbose", "v", false,
		"verbose orchestrator output (per-cell stdout/stderr is always streamed)")
	rootCmd.PersistentFlags().BoolVarP(&flagQuiet, "quiet", "q", false,
		"only print one summary line per cell")

	rootCmd.AddCommand(newRunCmd())
	rootCmd.AddCommand(newValidateCmd())
	rootCmd.AddCommand(newAggregateCmd())
	rootCmd.AddCommand(newReportCmd())
	rootCmd.AddCommand(newCompareCmd())
	rootCmd.AddCommand(newManifestCmd())
	rootCmd.AddCommand(newVersionCmd())
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the bench binary's full build info",
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintln(cmd.OutOrStdout(), version.Long())
		},
	}
}
