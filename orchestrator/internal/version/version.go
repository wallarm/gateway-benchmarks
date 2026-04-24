// Package version exposes build-time metadata embedded into the
// orchestrator binary via ldflags. Defaults are set so a "go run"
// build still works for development.
//
// Example ldflags (set by the Makefile bench-build target):
//
//	-X github.com/wallarm/gateway-benchmarks/orchestrator/internal/version.Version=v0.1.0
//	-X github.com/wallarm/gateway-benchmarks/orchestrator/internal/version.GitSHA=$(git rev-parse HEAD)
//	-X github.com/wallarm/gateway-benchmarks/orchestrator/internal/version.GitDirty=true
//	-X github.com/wallarm/gateway-benchmarks/orchestrator/internal/version.BuildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)
package version

import (
	"fmt"
	"runtime"
)

// Build-time metadata. Override via -ldflags "-X ...".
var (
	Version   = "dev"
	GitSHA    = "unknown"
	GitDirty  = "false"
	BuildTime = "unknown"
)

// Short returns "v0.1.0 (abcdef0)" or "dev (unknown)".
func Short() string {
	sha := GitSHA
	if len(sha) > 7 {
		sha = sha[:7]
	}
	dirty := ""
	if GitDirty == "true" {
		dirty = "+dirty"
	}
	return fmt.Sprintf("%s (%s%s)", Version, sha, dirty)
}

// Long returns a multi-line, machine-friendly version banner.
func Long() string {
	return fmt.Sprintf(
		"bench %s\n"+
			"  git sha:    %s\n"+
			"  git dirty:  %s\n"+
			"  build time: %s\n"+
			"  go runtime: %s %s/%s",
		Version, GitSHA, GitDirty, BuildTime,
		runtime.Version(), runtime.GOOS, runtime.GOARCH,
	)
}
