package cmd

import (
	"fmt"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

func newAggregateCmd() *cobra.Command {
	var (
		runID    string
		csvPath  string
		jsonPath string
		mdPath   string
	)

	cmd := &cobra.Command{
		Use:   "aggregate",
		Short: "Re-aggregate per-cell artefacts into matrix.csv / cells.jsonl / matrix.md",
		Long: `aggregate walks reports/<run-id>/raw/ and emits the canonical
31-column wide CSV (27 legacy + 4 bandwidth) plus a JSONL superset and a short markdown rollup.

This is the same projection scripts/aggregate-csv.sh produces, just
implemented natively in Go so the orchestrator doesn't need jq/awk
present on the loadgen host.

Default outputs (when --csv / --jsonl / --md are not given):

  reports/<run-id>/matrix.csv
  reports/<run-id>/cells.jsonl
  reports/<run-id>/matrix.md`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if runID == "" {
				if flagRunID == "" {
					return fmt.Errorf("--run-id is required (or pass --run-id at the root level)")
				}
				runID = flagRunID
			}

			agg := &aggregate.Aggregator{RepoRoot: flagRepoRoot, RunID: runID}
			cells, err := agg.Collect()
			if err != nil {
				return err
			}

			runDir := filepath.Join(flagRepoRoot, "reports", runID)
			if csvPath == "" {
				csvPath = filepath.Join(runDir, "matrix.csv")
			}
			if jsonPath == "" {
				jsonPath = filepath.Join(runDir, "cells.jsonl")
			}
			if mdPath == "" {
				mdPath = filepath.Join(runDir, "matrix.md")
			}

			if err := agg.WriteCSV(csvPath, cells); err != nil {
				return fmt.Errorf("write csv: %w", err)
			}
			if err := agg.WriteJSONL(jsonPath, cells); err != nil {
				return fmt.Errorf("write jsonl: %w", err)
			}
			if err := agg.WriteMarkdown(mdPath, cells); err != nil {
				return fmt.Errorf("write md: %w", err)
			}

			fmt.Fprintf(cmd.OutOrStdout(), "wrote %d cells\n", len(cells))
			fmt.Fprintf(cmd.OutOrStdout(), "  csv:   %s\n", csvPath)
			fmt.Fprintf(cmd.OutOrStdout(), "  jsonl: %s\n", jsonPath)
			fmt.Fprintf(cmd.OutOrStdout(), "  md:    %s\n", mdPath)
			return nil
		},
	}

	cmd.Flags().StringVar(&runID, "run-id", "", "report run id (e.g. 20260423T120000Z)")
	cmd.Flags().StringVar(&csvPath, "csv", "", "override matrix.csv output path")
	cmd.Flags().StringVar(&jsonPath, "jsonl", "", "override cells.jsonl output path")
	cmd.Flags().StringVar(&mdPath, "md", "", "override matrix.md output path")

	return cmd
}
