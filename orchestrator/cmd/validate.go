package cmd

import (
	"context"
	"fmt"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/parity"
)

func newValidateCmd() *cobra.Command {
	var (
		gatewaysCSV string
		policiesCSV string
		target      string
		backendPeek string
		runID       string
		stopOnFail  bool
	)

	cmd := &cobra.Command{
		Use:   "validate",
		Short: "Run parity-attestation.sh against one or more (gateway, policy) pairs",
		Long: `validate runs scripts/parity-attestation.sh for the cartesian product of
--gateways and --policies, with no load. Use it to confirm a stack is
healthy before kicking off a full bench run, or to triage a previously
failing cell in isolation.

Each (gateway, policy) pair writes parity.json under
reports/<run-id>/raw/<gateway>/<policy>__validate__<scenario>/.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			if ctx == nil {
				ctx = context.Background()
			}
			if runID == "" {
				if flagRunID != "" {
					runID = flagRunID
				} else {
					runID = time.Now().UTC().Format("20060102T150405Z")
				}
			}

			gws := resolveSelection("gateways", gatewaysCSV, []string{"nginx"})
			pols := resolveSelection("policies", policiesCSV, matrix.CanonicalPolicies)

			chk := &parity.Checker{
				RepoRoot: flagRepoRoot,
				Target:   target,
				Backend:  backendPeek,
				Logger:   cmd.OutOrStderr(),
			}

			var pass, fail, fm, errs int
			for _, gw := range gws {
				for _, p := range pols {
					out := filepath.Join("reports", runID, "raw", gw,
						fmt.Sprintf("%s__validate__%s", p, matrix.ScenarioFor(p)))
					rep, err := chk.Check(ctx, gw, p, out)
					switch rep.Status {
					case parity.StatusPass:
						pass++
						fmt.Fprintf(cmd.OutOrStdout(), "PASS  %s/%s\n", gw, p)
					case parity.StatusFeatureMissing:
						fm++
						fmt.Fprintf(cmd.OutOrStdout(), "FM    %s/%s — %s\n", gw, p, rep.Reason)
					case parity.StatusFail:
						fail++
						fmt.Fprintf(cmd.OutOrStdout(), "FAIL  %s/%s — %s\n", gw, p, rep.Reason)
						if stopOnFail {
							return fmt.Errorf("stop-on-fail: %s/%s", gw, p)
						}
					default:
						errs++
						fmt.Fprintf(cmd.OutOrStdout(), "ERR   %s/%s — %v\n", gw, p, err)
					}
				}
			}

			total := pass + fail + fm + errs
			fmt.Fprintln(cmd.OutOrStdout(), "")
			fmt.Fprintln(cmd.OutOrStdout(), "=== validate complete ===")
			fmt.Fprintf(cmd.OutOrStdout(), "  PASS:           %d/%d\n", pass, total)
			fmt.Fprintf(cmd.OutOrStdout(), "  FEATURE_MISSING:%d/%d\n", fm, total)
			fmt.Fprintf(cmd.OutOrStdout(), "  FAIL:           %d/%d\n", fail, total)
			if errs > 0 {
				fmt.Fprintf(cmd.OutOrStdout(), "  ERROR:          %d/%d\n", errs, total)
			}
			if fail > 0 || errs > 0 {
				return fmt.Errorf("validate ended with %d non-PASS pairs", fail+errs)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&gatewaysCSV, "gateways", "nginx", "comma-separated gateways or 'all'")
	cmd.Flags().StringVar(&policiesCSV, "policies", "all", "comma-separated policies or 'all'/'core'")
	cmd.Flags().StringVar(&target, "target", "", "gateway URL forwarded to parity-attestation.sh (default http://localhost:9080)")
	cmd.Flags().StringVar(&backendPeek, "backend-peek", "", "backend URL forwarded to --backend-peek")
	cmd.Flags().StringVar(&runID, "run-id", "", "override the timestamp run id used for parity.json output")
	cmd.Flags().BoolVar(&stopOnFail, "stop-on-fail", false, "halt on the first FAIL")

	return cmd
}
