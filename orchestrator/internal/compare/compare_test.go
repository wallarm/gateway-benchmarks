package compare

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// ---- metricDelta ---------------------------------------------------------

func TestMetricDeltaWithinTolerance(t *testing.T) {
	cases := []struct {
		name       string
		a, b, tol  float64
		wantWithin bool
	}{
		{"identical", 100, 100, 0.03, true},
		{"within 3%", 100, 102.5, 0.03, true},
		{"at 3% on the dot", 100, 103, 0.03, true},
		{"over 3%", 100, 104, 0.03, false},
		{"both zero", 0, 0, 0.03, true},
		{"one zero", 0, 1, 0.10, false},
		{"negative bias handled", 200, 180, 0.10, true},
		{"negative bias outside", 200, 150, 0.10, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := metricDelta("x", "rps", tc.a, tc.b, tc.tol)
			if m.WithinLimit != tc.wantWithin {
				t.Fatalf("a=%v b=%v tol=%v → WithinLimit=%v want=%v (rel=%.4f)",
					tc.a, tc.b, tc.tol, m.WithinLimit, tc.wantWithin, m.RelDiff)
			}
		})
	}
}

// ---- identity ------------------------------------------------------------

func TestIdentityChecksMatching(t *testing.T) {
	a := &ManifestView{
		Git:          map[string]any{"sha": "abc123"},
		K6:           map[string]any{"digest": "sha256:deadbeef"},
		Seed:         42,
		SelectedRows: []string{"nginx/p01-vanilla/p1-baseline/s01-vanilla-http"},
	}
	b := &ManifestView{
		Git:          map[string]any{"sha": "abc123"},
		K6:           map[string]any{"digest": "sha256:deadbeef"},
		Seed:         42,
		SelectedRows: []string{"nginx/p01-vanilla/p1-baseline/s01-vanilla-http"},
	}
	checks := identityChecks(a, b)
	for _, c := range checks {
		if c.Missing {
			t.Fatalf("unexpected Missing on %s", c.Name)
		}
		if !c.Match {
			t.Fatalf("%s did not match: %q vs %q", c.Name, c.ValueA, c.ValueB)
		}
	}
}

func TestIdentityChecksMissing(t *testing.T) {
	checks := identityChecks(nil, nil)
	if len(checks) != 1 || !checks[0].Missing {
		t.Fatalf("expected a single SKIP identity check, got %+v", checks)
	}
}

func TestIdentityChecksDivergent(t *testing.T) {
	a := &ManifestView{
		Git:  map[string]any{"sha": "a"},
		K6:   map[string]any{"digest": "sha256:X"},
		Seed: 1,
	}
	b := &ManifestView{
		Git:  map[string]any{"sha": "b"},
		K6:   map[string]any{"digest": "sha256:Y"},
		Seed: 2,
	}
	checks := identityChecks(a, b)
	mismatches := 0
	for _, c := range checks {
		if !c.Match && !c.Missing {
			mismatches++
		}
	}
	if mismatches < 3 {
		t.Fatalf("expected at least 3 mismatches, got %d (%+v)", mismatches, checks)
	}
}

// ---- cellDiffs -----------------------------------------------------------

func mkCell(gw, policy, load, scenario string, rps, p95 float64) aggregate.Cell {
	return aggregate.Cell{
		Gateway:            gw,
		Policy:             policy,
		Load:               load,
		Scenario:           scenario,
		Verdict:            "PASS",
		HTTPReqRate:        rps,
		HTTPReqDurationP50: p95 * 0.7,
		HTTPReqDurationP95: p95,
		HTTPReqDurationP99: p95 * 1.3,
		MemRSSPeakBytes:    100 * 1024 * 1024,
		MemRSSSteadyBytes:  80 * 1024 * 1024,
	}
}

func TestCellDiffsMatchAndDiverge(t *testing.T) {
	a := []aggregate.Cell{
		mkCell("nginx", "p01-vanilla", "p1-baseline", "s01-vanilla-http", 1000, 1.0),
		mkCell("envoy", "p01-vanilla", "p1-baseline", "s01-vanilla-http", 800, 1.2),
	}
	b := []aggregate.Cell{
		mkCell("nginx", "p01-vanilla", "p1-baseline", "s01-vanilla-http", 1005, 1.02),
		mkCell("envoy", "p01-vanilla", "p1-baseline", "s01-vanilla-http", 600, 3.0),
	}

	diffs := cellDiffs(a, b, DefaultTolerances())
	if len(diffs) != 2 {
		t.Fatalf("got %d diffs, want 2 (%+v)", len(diffs), diffs)
	}

	// nginx cell stays within tolerance (0.5% RPS, 2% p95)
	for _, d := range diffs {
		if d.Key.Gateway == "nginx" && !d.WithinAll {
			t.Errorf("nginx should be within tolerance, got %+v", d.Metrics)
		}
		if d.Key.Gateway == "envoy" && d.WithinAll {
			t.Errorf("envoy should diverge (RPS 800→600, p95 1.2→3.0)")
		}
	}
}

func TestCellDiffsOnlyInOneSide(t *testing.T) {
	a := []aggregate.Cell{mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)}
	b := []aggregate.Cell{mkCell("envoy", "p01", "p1", "s01", 1000, 1.0)}

	diffs := cellDiffs(a, b, DefaultTolerances())
	if len(diffs) != 2 {
		t.Fatalf("expected 2 diffs, got %d", len(diffs))
	}
	var onlyA, onlyB int
	for _, d := range diffs {
		if d.OnlyInA {
			onlyA++
		}
		if d.OnlyInB {
			onlyB++
		}
	}
	if onlyA != 1 || onlyB != 1 {
		t.Fatalf("onlyA=%d onlyB=%d (%+v)", onlyA, onlyB, diffs)
	}
}

func TestCellDiffsVerdictMismatchBreaksTolerance(t *testing.T) {
	a := mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)
	b := mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)
	b.Verdict = "FAIL"

	d := diffCell(CellKey{"nginx", "p01", "p1", "s01"}, a, b, DefaultTolerances())
	if d.WithinAll {
		t.Fatalf("expected FAIL vs PASS to break tolerance, got %+v", d)
	}
}

func TestCellDiffsErrorMustMatch(t *testing.T) {
	a := mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)
	b := mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)
	a.Policy5xxUnexpected = 0
	b.Policy5xxUnexpected = 3

	d := diffCell(CellKey{"nginx", "p01", "p1", "s01"}, a, b, DefaultTolerances())
	if d.WithinAll {
		t.Fatalf("5xx divergence should break tolerance")
	}
	found := false
	for _, e := range d.ErrorMis {
		if e.Name == "policy_5xx_unexpected" && e.CountA == 0 && e.CountB == 3 {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected 5xx mismatch in ErrorMis, got %+v", d.ErrorMis)
	}
}

// ---- rankStability -------------------------------------------------------

func TestRankStabilityAgrees(t *testing.T) {
	a := []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 900, 1.2),
		mkCell("kong", "p01", "p1", "s01", 700, 1.5),
	}
	b := []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1010, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 910, 1.2),
		mkCell("kong", "p01", "p1", "s01", 690, 1.5),
	}
	breaks := rankStability(a, b, 3)
	if len(breaks) != 0 {
		t.Fatalf("expected no rank breaks, got %+v", breaks)
	}
}

func TestRankStabilityBreaks(t *testing.T) {
	a := []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 900, 1.2),
		mkCell("kong", "p01", "p1", "s01", 700, 1.5),
	}
	// Envoy regressed hard, kong now second.
	b := []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 500, 1.2),
		mkCell("kong", "p01", "p1", "s01", 700, 1.5),
	}
	breaks := rankStability(a, b, 3)
	if len(breaks) != 1 {
		t.Fatalf("expected 1 rank break, got %d (%+v)", len(breaks), breaks)
	}
	rb := breaks[0]
	if rb.OrderA[1] != "envoy" || rb.OrderB[1] != "kong" {
		t.Fatalf("unexpected order: A=%v B=%v", rb.OrderA, rb.OrderB)
	}
}

// ---- Compare() end-to-end ------------------------------------------------

func TestCompareReproducibleVerdict(t *testing.T) {
	a := Input{
		Label:    "run-A",
		Manifest: &ManifestView{Git: map[string]any{"sha": "abc"}, K6: map[string]any{"digest": "d"}, Seed: 42, SelectedRows: []string{"r"}},
		Cells: []aggregate.Cell{
			mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
			mkCell("envoy", "p01", "p1", "s01", 800, 1.2),
		},
	}
	b := Input{
		Label:    "run-B",
		Manifest: &ManifestView{Git: map[string]any{"sha": "abc"}, K6: map[string]any{"digest": "d"}, Seed: 42, SelectedRows: []string{"r"}},
		Cells: []aggregate.Cell{
			mkCell("nginx", "p01", "p1", "s01", 1005, 1.01),
			mkCell("envoy", "p01", "p1", "s01", 798, 1.22),
		},
	}
	s := Compare(a, b, DefaultTolerances())
	if s.ExitCode() != 0 {
		t.Fatalf("expected reproducible, got exit=%d identical=%v within=%v rank=%v",
			s.ExitCode(), s.Identical, s.WithinToler, s.RankStable)
	}
}

func TestCompareNotReproducibleNumeric(t *testing.T) {
	a := Input{Cells: []aggregate.Cell{mkCell("nginx", "p01", "p1", "s01", 1000, 1.0)}}
	b := Input{Cells: []aggregate.Cell{mkCell("nginx", "p01", "p1", "s01", 2000, 1.0)}}
	s := Compare(a, b, DefaultTolerances())
	if s.ExitCode() != 2 {
		t.Fatalf("expected exit=2 on RPS doubling, got %d", s.ExitCode())
	}
	if s.WithinToler {
		t.Fatalf("expected WithinToler=false")
	}
}

func TestCompareNotReproducibleRank(t *testing.T) {
	a := Input{Cells: []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 900, 1.0),
	}}
	b := Input{Cells: []aggregate.Cell{
		mkCell("nginx", "p01", "p1", "s01", 1000, 1.0),
		mkCell("envoy", "p01", "p1", "s01", 1100, 1.0),
	}}
	s := Compare(a, b, DefaultTolerances())
	if s.RankStable {
		t.Fatalf("expected RankStable=false when top-2 flipped")
	}
	if s.ExitCode() != 2 {
		t.Fatalf("expected exit=2, got %d", s.ExitCode())
	}
}

// ---- RenderText ----------------------------------------------------------

func TestRenderTextIncludesVerdict(t *testing.T) {
	s := &Summary{Identical: true, WithinToler: true, RankStable: true}
	txt := RenderText(s, "run-A", "run-B")
	if !strings.Contains(txt, "verdict: REPRODUCIBLE") {
		t.Fatalf("expected REPRODUCIBLE verdict, got:\n%s", txt)
	}
}

// ---- Load ----------------------------------------------------------------

func TestLoadJSONLAndManifest(t *testing.T) {
	tmp := t.TempDir()
	runDir := filepath.Join(tmp, "reports", "unit-test")
	if err := os.MkdirAll(runDir, 0o755); err != nil {
		t.Fatal(err)
	}

	cells := []aggregate.Cell{
		mkCell("nginx", "p01-vanilla", "p1-baseline", "s01-vanilla-http", 1000, 1.0),
	}
	jf, err := os.Create(filepath.Join(runDir, "cells.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	enc := json.NewEncoder(jf)
	for _, c := range cells {
		if err := enc.Encode(c); err != nil {
			t.Fatal(err)
		}
	}
	_ = jf.Close()

	mf := ManifestView{
		SchemaVersion: "1",
		RunID:         "unit-test",
		Git:           map[string]any{"sha": "abc"},
		K6:            map[string]any{"digest": "sha256:x"},
		Seed:          42,
	}
	if err := os.WriteFile(filepath.Join(runDir, "manifest.json"), mustJSON(t, mf), 0o644); err != nil {
		t.Fatal(err)
	}

	in, err := Load(LoadOptions{RepoRoot: tmp, RunID: "unit-test"})
	if err != nil {
		t.Fatal(err)
	}
	if len(in.Cells) != 1 {
		t.Fatalf("expected 1 cell, got %d", len(in.Cells))
	}
	if in.Manifest == nil || in.Manifest.Seed != 42 {
		t.Fatalf("manifest not loaded: %+v", in.Manifest)
	}
}

func mustJSON(t *testing.T, v interface{}) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
