package report

import (
	"math"
	"strings"
	"testing"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/classify"
)

func mkCell(gw, policy, load string, rps float64, p50, p95 float64, opts ...func(*aggregate.Cell)) aggregate.Cell {
	c := aggregate.Cell{
		Gateway:             gw,
		Policy:              policy,
		Load:                load,
		Scenario:            "s01-vanilla-http",
		RunID:               "r1",
		Verdict:             "PASS",
		ParityStatus:        "PASS",
		HTTPReqs:            int64(rps * 60),
		HTTPReqRate:         rps,
		HTTPReqDurationP50:  p50,
		HTTPReqDurationP95:  p95,
		HTTPReqDurationMax:  p95 * 3,
		Policy2xx:           int64(rps * 60),
		MemRSSPeakBytes:     128 * 1024 * 1024,
		MemRSSSteadyBytes:   100 * 1024 * 1024,
		Health:              classify.HealthGreen,
	}
	for _, o := range opts {
		o(&c)
	}
	return c
}

func TestErrRatio(t *testing.T) {
	cases := []struct {
		name string
		c    aggregate.Cell
		want float64
	}{
		{"all-2xx", aggregate.Cell{Policy2xx: 1000}, 0},
		{"half-5xx", aggregate.Cell{Policy2xx: 500, Policy5xxUnexpected: 500}, 0.5},
		{"429-not-error", aggregate.Cell{Policy2xx: 100, Policy4xxExpected: 900}, 0},
		{"empty", aggregate.Cell{}, 0},
		{"4xx-unexpected", aggregate.Cell{Policy2xx: 80, Policy4xxUnexpected: 20}, 0.2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := errRatio(tc.c)
			if math.Abs(got-tc.want) > 1e-9 {
				t.Fatalf("errRatio: got %v want %v", got, tc.want)
			}
		})
	}
}

func TestBuildIndexAndUnstable(t *testing.T) {
	// Two reps for nginx/p01 with a 20% spread → unstable.
	// One rep for envoy → stable by definition.
	cells := []aggregate.Cell{
		mkCell("nginx", "p01-vanilla", "p1-baseline", 20000, 0.3, 1.2),
		func() aggregate.Cell {
			c := mkCell("nginx", "p01-vanilla", "p1-baseline", 16000, 0.3, 1.2)
			return c
		}(),
		mkCell("envoy", "p01-vanilla", "p1-baseline", 18000, 0.4, 1.5),
	}
	idx := BuildIndex(cells, 0.05)
	if got := idx.Buckets["p01-vanilla"]["nginx"]["p1-baseline"]; !got.Unstable {
		t.Fatalf("expected nginx/p01/p1-baseline to be unstable; got %+v", got)
	}
	if got := idx.Buckets["p01-vanilla"]["envoy"]["p1-baseline"]; got.Unstable {
		t.Fatalf("envoy single-rep cell should not be unstable; got %+v", got)
	}
}

func TestBuildSummarySortedByRPS(t *testing.T) {
	cells := []aggregate.Cell{
		mkCell("envoy", "p01-vanilla", "p1-baseline", 19000, 0.4, 1.5),
		mkCell("nginx", "p01-vanilla", "p1-baseline", 20000, 0.3, 1.2),
		mkCell("kong", "p01-vanilla", "p1-baseline", 8000, 0.7, 2.5),
	}
	idx := BuildIndex(cells, 0)
	rows := BuildSummary(idx, []string{"p1-baseline"})
	if len(rows) != 3 {
		t.Fatalf("want 3 rows, got %d", len(rows))
	}
	if rows[0].Gateway != "nginx" || rows[1].Gateway != "envoy" || rows[2].Gateway != "kong" {
		t.Fatalf("rank order off: %+v", rows)
	}
	if rows[0].Coverage != "1/1" {
		t.Fatalf("coverage: want 1/1 got %s", rows[0].Coverage)
	}
}

func TestParityLineShapes(t *testing.T) {
	all := mkCell("nginx", "p01-vanilla", "p1-baseline", 1, 1, 1)
	excluded := all
	excluded.Gateway = "tyk"
	excluded.Verdict = "EXCLUDED"
	failed := all
	failed.Gateway = "kong"
	failed.Verdict = "FAIL"

	idx := BuildIndex([]aggregate.Cell{all, excluded, failed}, 0)
	tabs := BuildTabs(idx, []string{"p1-baseline"})
	if len(tabs) != 1 {
		t.Fatalf("expected 1 tab, got %d", len(tabs))
	}
	got := tabs[0].ParityLine
	if !strings.Contains(got, "1 PASS") || !strings.Contains(got, "1 EXCLUDED") || !strings.Contains(got, "1 FAIL") {
		t.Fatalf("parity line missing parts: %q", got)
	}

	allPassIdx := BuildIndex([]aggregate.Cell{all}, 0)
	allTabs := BuildTabs(allPassIdx, []string{"p1-baseline"})
	if got := allTabs[0].ParityLine; got != "All 1 PASS" {
		t.Fatalf("all-pass shape wrong: got %q", got)
	}
}

func TestBuildLoadGroupWinnersAndBrokenTiming(t *testing.T) {
	pass := mkCell("nginx", "p01-vanilla", "p1-baseline", 20000, 0.3, 1.2)
	broken := mkCell("tyk", "p01-vanilla", "p1-baseline", 30000, 0, 0)
	broken.HTTPReqDurationMax = 0
	broken.TimingBroken = true
	mid := mkCell("envoy", "p01-vanilla", "p1-baseline", 18000, 0.4, 1.5)

	idx := BuildIndex([]aggregate.Cell{pass, broken, mid}, 0)
	tabs := BuildTabs(idx, []string{"p1-baseline"})
	if len(tabs) != 1 || len(tabs[0].Loads) != 1 {
		t.Fatalf("want 1 tab/1 load, got %+v", tabs)
	}
	g := tabs[0].Loads[0]
	if g.RPSWinner == nil || g.RPSWinner.Gateway != "tyk" {
		t.Fatalf("RPS winner: want tyk, got %+v", g.RPSWinner)
	}
	if g.LatWinner == nil || g.LatWinner.Gateway != "nginx" {
		t.Fatalf("Lat winner: want nginx (lowest p95 with valid timing), got %+v", g.LatWinner)
	}
}

func TestBuildChartDataJSONNullsBrokenTiming(t *testing.T) {
	pass := mkCell("nginx", "p01-vanilla", "p1-baseline", 20000, 0.3, 1.2)
	broken := mkCell("tyk", "p01-vanilla", "p1-baseline", 30000, 0, 0)
	broken.HTTPReqDurationMax = 0
	broken.TimingBroken = true
	idx := BuildIndex([]aggregate.Cell{pass, broken}, 0)
	tabs := BuildTabs(idx, []string{"p1-baseline"})
	js, err := BuildChartDataJSON(tabs)
	if err != nil {
		t.Fatalf("BuildChartDataJSON: %v", err)
	}
	// Tyk has TimingBroken → its p50/p95 must be null in the JSON.
	if !strings.Contains(js, "null") {
		t.Fatalf("expected at least one null in chart JSON; got %s", js)
	}
}
