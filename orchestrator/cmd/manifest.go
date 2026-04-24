package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/spf13/cobra"
)

func newManifestCmd() *cobra.Command {
	var (
		runID string
		latest bool
	)

	cmd := &cobra.Command{
		Use:   "manifest",
		Short: "Print the manifest.json of a benchmark run",
		Long: `manifest reads reports/<run-id>/manifest.json and prints it on stdout.

Use --latest (default) to pick the most recent run by directory name.
Pass --run-id explicitly to inspect a specific run.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if runID == "" {
				if flagRunID != "" {
					runID = flagRunID
				} else if latest {
					rid, err := pickLatestRun(flagRepoRoot)
					if err != nil {
						return err
					}
					runID = rid
				} else {
					return fmt.Errorf("--run-id is required when --latest is false")
				}
			}

			path := filepath.Join(flagRepoRoot, "reports", runID, "manifest.json")
			data, err := os.ReadFile(path)
			if err != nil {
				return fmt.Errorf("read manifest: %w", err)
			}
			fmt.Fprintln(cmd.OutOrStdout(), string(data))
			return nil
		},
	}

	cmd.Flags().StringVar(&runID, "run-id", "", "specific run id to inspect")
	cmd.Flags().BoolVar(&latest, "latest", true, "pick the most recent reports/* directory")

	return cmd
}

func pickLatestRun(repoRoot string) (string, error) {
	dir := filepath.Join(repoRoot, "reports")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", fmt.Errorf("read reports/: %w", err)
	}
	var ids []string
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		// Run IDs are timestamps shaped like YYYYMMDDTHHMMSSZ — 16 chars.
		if len(name) == 16 && name[8] == 'T' && name[15] == 'Z' {
			ids = append(ids, name)
		}
	}
	if len(ids) == 0 {
		return "", fmt.Errorf("no timestamped run directories under %s", dir)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(ids)))
	return ids[0], nil
}
