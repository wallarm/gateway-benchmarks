package report

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// TestRenderEndToEnd is a low-cost integration check that exercises
// every layer (load → derive → execute template → write file) without
// spinning up gateways. It writes the output into the test's temp dir
// so it is deleted automatically.
func TestRenderEndToEnd(t *testing.T) {
	tmp := t.TempDir()
	out := filepath.Join(tmp, "report.html")

	cells := []aggregate.Cell{
		{
			Gateway: "nginx", Policy: "p01-vanilla", Scenario: "s01-vanilla-http",
			Load: "p1-baseline", RunID: "smoke", Verdict: "PASS", ParityStatus: "PASS",
			HTTPReqs: 1000, HTTPReqRate: 18000,
			HTTPReqDurationP50: 0.3, HTTPReqDurationP90: 0.5, HTTPReqDurationP95: 1.2,
			HTTPReqDurationMax: 5.0, IterDurationAvgMs: 0.4,
			Policy2xx: 1000, MemRSSPeakBytes: 110 * 1024 * 1024, MemRSSSteadyBytes: 100 * 1024 * 1024,
		},
		{
			Gateway: "envoy", Policy: "p01-vanilla", Scenario: "s01-vanilla-http",
			Load: "p1-baseline", RunID: "smoke", Verdict: "PASS", ParityStatus: "PASS",
			HTTPReqs: 800, HTTPReqRate: 16000,
			HTTPReqDurationP50: 0.4, HTTPReqDurationP90: 0.6, HTTPReqDurationP95: 1.3,
			HTTPReqDurationMax: 6.0, IterDurationAvgMs: 0.5,
			Policy2xx: 800, MemRSSPeakBytes: 90 * 1024 * 1024, MemRSSSteadyBytes: 80 * 1024 * 1024,
		},
		{
			// timing-broken cell — must surface in the HeroNote
			Gateway: "tyk", Policy: "p01-vanilla", Scenario: "s01-vanilla-http",
			Load: "p1-baseline", RunID: "smoke", Verdict: "PASS", ParityStatus: "PASS",
			HTTPReqs: 1500, HTTPReqRate: 30000,
			HTTPReqDurationP50: 0, HTTPReqDurationP95: 0, HTTPReqDurationMax: 0,
			Policy2xx: 1500, MemRSSPeakBytes: 70 * 1024 * 1024, MemRSSSteadyBytes: 60 * 1024 * 1024,
			TimingBroken: true,
		},
		{
			// EXCLUDED cell — must appear in the table tail
			Gateway: "kong", Policy: "p10-req-body", Scenario: "s10-req-body-http",
			Load: "p1-baseline", RunID: "smoke", Verdict: "EXCLUDED",
			ParityStatus: "FEATURE_MISSING",
		},
	}

	loaded := &Loaded{
		Cells: cells,
		RunDir: tmp,
		Manifest: &Manifest{
			SchemaVersion: "1",
			RunID:         "smoke",
			Mode:          "local",
			Bench:         BenchInfo{Version: "test", GitSHA: "abcdef0123456", BuildTime: "2026-04-24T07:00:00Z"},
			Git:           GitInfo{SHA: "abcdef0123456", Branch: "main", HasGit: true},
			K6:            K6Info{Image: "grafana/k6:1.7.1@sha256:deadbeef", Digest: "sha256:deadbeef"},
			Host:          HostInfo{OS: "darwin", Arch: "arm64", NumCPU: 14, Hostname: "test"},
			Notes:         "render smoke",
		},
	}

	wrote, err := Render(loaded, Options{
		Title:      "Render smoke",
		OutputPath: out,
	})
	if err != nil {
		t.Fatalf("Render: %v", err)
	}
	if wrote != out {
		t.Fatalf("wrote=%q want %q", wrote, out)
	}

	body, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("read output: %v", err)
	}
	if len(body) < 4096 {
		t.Fatalf("output suspiciously small: %d bytes", len(body))
	}

	mustContain := []string{
		"Render smoke",                             // hero title
		"Executive Summary",                        // section
		"Memory Footprint",                         // section
		"Overall Profile",                          // radar section
		"Policy Details",                           // tabs section
		"p01 · vanilla",                            // policy label
		"All 3 PASS",                               // p01 has 3 PASS rows
		"FEATURE-MISSING",                          // EXCLUDED tail
		"Known measurement gap",                    // hero note (broken timing)
		"tyk",                                      // gateway badge
		"chart.js@4",                               // CDN script tag
		"chart-rps-p01-vanilla-p1-baseline",        // canvas id
		"chart-lat-p01-vanilla-p1-baseline",        // canvas id
		"radarChart",                               // radar canvas
	}
	for _, m := range mustContain {
		if !strings.Contains(string(body), m) {
			t.Fatalf("output missing %q\n--- start of body ---\n%s\n--- end of body ---",
				m, truncate(string(body), 2048))
		}
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
