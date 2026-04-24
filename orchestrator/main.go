// bench is the orchestrator described in orchestrator/README.md.
// It drives the (gateway × policy × scenario × load) matrix, stamping
// every run with a manifest.json that pins source SHA, image
// digests, k6 version and host info, then aggregates per-cell
// artefacts into a wide CSV / JSONL / markdown rollup.
//
// All subcommand wiring lives under cmd/.
package main

import (
	"fmt"
	"os"

	"github.com/wallarm/gateway-benchmarks/orchestrator/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "bench: %v\n", err)
		os.Exit(1)
	}
}
