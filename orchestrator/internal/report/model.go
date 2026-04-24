package report

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// Cell is the per-cell row consumed by the renderer. It is a thin
// projection of aggregate.Cell with derived UI flags pre-computed
// once so the template stays declarative.
type Cell struct {
	aggregate.Cell

	// ErrRatio is policy_4xx_unexpected + policy_5xx_unexpected
	// divided by the classified-total. Mirrors render-html-report.py
	// § _err_rate. 0–1.
	ErrRatio float64

	// Unstable is set when a cell is part of a multi-rep run whose
	// RPS spread (max-min)/mean exceeds the unstable threshold.
	// Default threshold: 5%. Single-rep cells are never unstable.
	Unstable bool
}

// Index is gateway -> policy -> load -> Cell. We project the whole
// (gateway, policy, scenario, load, rep) cube down to the most
// interesting representative per (gateway, policy, load) bucket: the
// rep with the median RPS. Repetition spread feeds the Unstable flag.
type Index struct {
	// Buckets keyed by [policy][gateway][load] → representative Cell.
	Buckets map[string]map[string]map[string]Cell

	// AllRepsByCell[policy][gateway][load] → every rep we saw.
	// Used for variance / unstable derivations.
	AllRepsByCell map[string]map[string]map[string][]Cell

	// All cells in input order (post-stable-sort by aggregate). Used
	// to count PASS/EXCLUDED/FAIL totals for the footer.
	All []Cell
}

// SummaryRow is one entry of the executive summary table.
type SummaryRow struct {
	Gateway     string
	Stack       [2]string
	AvgRPS      float64
	MaxErrPct   float64
	Coverage    string  // "12/12"
	PassCells   int
	TotalCells  int
	PeakRSSMB   float64
	SteadyRSSMB float64
}

// LoadGroup holds the chart data + table rows for one load profile
// inside a policy tab.
type LoadGroup struct {
	Load     string
	Meta     LoadProfileMeta
	Cells    []Cell // sorted by RPS descending; PASS only
	Excluded []Cell // tail-listed in the table
	// Pre-computed chart payloads. Latency arrays use a sentinel
	// (math.NaN) for cells whose timing instrumentation is broken;
	// the template marshals them as JSON null so Chart.js draws a gap.
	ChartLabels []string
	ChartRPS    []float64
	ChartP50    []float64
	ChartP95    []float64
	ChartColors []string
	// Winner banner picks. RPS winner = highest RPS; latency winner
	// = lowest p95 across cells with valid timing.
	RPSWinner *Cell
	LatWinner *Cell
}

// PolicyTab is one tab in the report (one per policy that has at
// least one cell of any verdict).
type PolicyTab struct {
	Policy      string
	Meta        PolicyMeta
	Loads       []LoadGroup
	ParityLine  string // e.g. "All 7 PASS" / "5 PASS · 2 EXCLUDED"
	HasUnstable bool
}

// RadarSeries is one line of the overall-profile radar chart.
type RadarSeries struct {
	Label                 string    `json:"label"`
	Data                  []float64 `json:"data"`
	BorderColor           string    `json:"borderColor"`
	BackgroundColor       string    `json:"backgroundColor"`
	PointBackgroundColor  string    `json:"pointBackgroundColor"`
}

// Footer carries the bottom-of-page totals.
type Footer struct {
	PassCount     int
	ExcludedCount int
	FailCount     int
	OtherCount    int
	RunIDs        []string
}

// View is the top-level template context. Everything the template
// needs comes from this struct — no template helpers reach back into
// Cell objects directly.
type View struct {
	Title        string
	GeneratedAt  string
	EnvLine      string
	HeroNote     string  // "Known measurement gap: ..." or empty
	HowToRead    string  // explanatory note shown at the top of the body

	Manifest     *Manifest
	Summary      []SummaryRow
	MemoryChips  []MemoryChip
	RadarLabels  []string
	RadarSeries  []RadarSeries
	Tabs         []PolicyTab
	Footer       Footer
	Downloads    Downloads

	// JSON-encoded payloads handed straight to the inline <script>.
	ChartDataJSON   string
	RadarLabelsJSON string
	RadarSeriesJSON string
	PoliciesJSON    string
}

// MemoryChip is one tile in the memory-footprint grid.
type MemoryChip struct {
	Gateway   string
	Color     string
	PeakRSSMB float64
}

// Downloads describes the buttons shown in the hero / floating bar.
// Paths are relative to the report.html location.
type Downloads struct {
	Manifest string // "manifest.json" or empty if not present
	CSV      string // "matrix.csv"     or empty
	JSONL    string // "cells.jsonl"    or empty
	Markdown string // "matrix.md"      or empty
}

// -----------------------------------------------------------------------------
// Derivations
// -----------------------------------------------------------------------------

// errRatio mirrors scripts/render-html-report.py § _err_rate. Returns
// 0..1 (NOT a percentage).
func errRatio(c aggregate.Cell) float64 {
	total := float64(c.Policy2xx + c.Policy4xxExpected + c.Policy4xxUnexpected + c.Policy5xxUnexpected)
	if total <= 0 {
		return 0
	}
	return float64(c.Policy4xxUnexpected+c.Policy5xxUnexpected) / total
}

// BuildIndex turns a flat slice of aggregate.Cell into the (policy,
// gateway, load) cube the renderer expects. unstableThreshold is the
// (max-min)/mean spread in [0, 1] above which a multi-rep cell is
// flagged unstable. Pass 0 to disable.
func BuildIndex(raw []aggregate.Cell, unstableThreshold float64) *Index {
	idx := &Index{
		Buckets:       make(map[string]map[string]map[string]Cell),
		AllRepsByCell: make(map[string]map[string]map[string][]Cell),
		All:           make([]Cell, 0, len(raw)),
	}

	// First pass: bucket every cell by (policy, gateway, load), keep
	// repetitions side-by-side so we can compute medians + spread.
	for _, r := range raw {
		c := Cell{Cell: r, ErrRatio: errRatio(r)}
		idx.All = append(idx.All, c)
		if c.Policy == "" || c.Gateway == "" || c.Load == "" {
			continue
		}
		if _, ok := idx.AllRepsByCell[c.Policy]; !ok {
			idx.AllRepsByCell[c.Policy] = make(map[string]map[string][]Cell)
		}
		if _, ok := idx.AllRepsByCell[c.Policy][c.Gateway]; !ok {
			idx.AllRepsByCell[c.Policy][c.Gateway] = make(map[string][]Cell)
		}
		idx.AllRepsByCell[c.Policy][c.Gateway][c.Load] =
			append(idx.AllRepsByCell[c.Policy][c.Gateway][c.Load], c)
	}

	// Second pass: pick the representative rep per bucket (median
	// RPS for PASS cells; first cell otherwise) + apply Unstable.
	for policy, byGW := range idx.AllRepsByCell {
		idx.Buckets[policy] = make(map[string]map[string]Cell)
		for gw, byLoad := range byGW {
			idx.Buckets[policy][gw] = make(map[string]Cell)
			for load, reps := range byLoad {
				rep, unstable := pickRepresentative(reps, unstableThreshold)
				rep.Unstable = unstable
				idx.Buckets[policy][gw][load] = rep
			}
		}
	}
	return idx
}

// pickRepresentative chooses the median-RPS rep among PASS cells.
// If no PASS rep exists, returns the first cell as-is. Also returns
// true when (max-min)/mean across PASS reps exceeds threshold.
func pickRepresentative(reps []Cell, threshold float64) (Cell, bool) {
	if len(reps) == 0 {
		return Cell{}, false
	}
	if len(reps) == 1 {
		return reps[0], false
	}

	pass := make([]Cell, 0, len(reps))
	for _, r := range reps {
		if r.Verdict == "PASS" {
			pass = append(pass, r)
		}
	}
	if len(pass) == 0 {
		return reps[0], false
	}
	sort.Slice(pass, func(i, j int) bool { return pass[i].HTTPReqRate < pass[j].HTTPReqRate })
	median := pass[len(pass)/2]

	if threshold <= 0 {
		return median, false
	}
	mn, mx, sum := pass[0].HTTPReqRate, pass[0].HTTPReqRate, 0.0
	for _, p := range pass {
		if p.HTTPReqRate < mn {
			mn = p.HTTPReqRate
		}
		if p.HTTPReqRate > mx {
			mx = p.HTTPReqRate
		}
		sum += p.HTTPReqRate
	}
	mean := sum / float64(len(pass))
	if mean <= 0 {
		return median, false
	}
	spread := (mx - mn) / mean
	return median, spread > threshold
}

// BuildSummary rolls every gateway up into one SummaryRow, sorted
// descending by avg RPS across the policies it actually attempted.
func BuildSummary(idx *Index, loads []string) []SummaryRow {
	gateways := gatewaysIn(idx)
	rows := make([]SummaryRow, 0, len(gateways))

	for _, gw := range gateways {
		var (
			rpsSum, maxErr, peakRSSBytes, steadyRSSBytes float64
			passCells, totalCells                        int
		)
		for _, policy := range PolicyOrder {
			byLoad, ok := idx.Buckets[policy][gw]
			if !ok {
				continue
			}
			for _, load := range loads {
				cell, ok := byLoad[load]
				if !ok {
					continue
				}
				totalCells++
				if cell.Verdict != "PASS" {
					continue
				}
				passCells++
				rpsSum += cell.HTTPReqRate
				if cell.ErrRatio*100 > maxErr {
					maxErr = cell.ErrRatio * 100
				}
				if float64(cell.MemRSSPeakBytes) > peakRSSBytes {
					peakRSSBytes = float64(cell.MemRSSPeakBytes)
				}
				if float64(cell.MemRSSSteadyBytes) > steadyRSSBytes {
					steadyRSSBytes = float64(cell.MemRSSSteadyBytes)
				}
			}
		}
		if totalCells == 0 {
			continue
		}
		var avgRPS float64
		if passCells > 0 {
			avgRPS = rpsSum / float64(passCells)
		}
		rows = append(rows, SummaryRow{
			Gateway:     gw,
			Stack:       GatewayStack[gw],
			AvgRPS:      avgRPS,
			MaxErrPct:   maxErr,
			Coverage:    fmt.Sprintf("%d/%d", passCells, totalCells),
			PassCells:   passCells,
			TotalCells:  totalCells,
			PeakRSSMB:   peakRSSBytes / (1024 * 1024),
			SteadyRSSMB: steadyRSSBytes / (1024 * 1024),
		})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].AvgRPS > rows[j].AvgRPS })
	return rows
}

// BuildMemoryChips returns one chip per gateway, sorted by peak RSS
// ascending (smallest first — the same order Python prototype used).
func BuildMemoryChips(rows []SummaryRow) []MemoryChip {
	chips := make([]MemoryChip, 0, len(rows))
	for _, r := range rows {
		chips = append(chips, MemoryChip{
			Gateway:   r.Gateway,
			Color:     GatewayColors[r.Gateway],
			PeakRSSMB: r.PeakRSSMB,
		})
	}
	sort.Slice(chips, func(i, j int) bool { return chips[i].PeakRSSMB < chips[j].PeakRSSMB })
	return chips
}

// BuildRadar projects every gateway's PASS RPS as a percentage of
// the per-policy winner. Uses p1-baseline by default; falls back to
// the first available load when p1-baseline is absent.
func BuildRadar(idx *Index, load string) ([]string, []RadarSeries) {
	gateways := gatewaysIn(idx)
	labels := make([]string, 0, len(PolicyOrder))
	for _, p := range PolicyOrder {
		if _, ok := idx.Buckets[p]; ok {
			labels = append(labels, PolicyDescriptions[p].Label)
		}
	}

	series := make([]RadarSeries, 0, len(gateways))
	for _, gw := range gateways {
		s := RadarSeries{
			Label:                gw,
			BorderColor:          GatewayColors[gw],
			BackgroundColor:      GatewayColors[gw] + "20",
			PointBackgroundColor: GatewayColors[gw],
			Data:                 make([]float64, 0, len(PolicyOrder)),
		}
		for _, policy := range PolicyOrder {
			byGW, ok := idx.Buckets[policy]
			if !ok {
				continue
			}
			best := 0.0
			for _, byLoad := range byGW {
				cell, ok := byLoad[load]
				if !ok || cell.Verdict != "PASS" {
					continue
				}
				if cell.HTTPReqRate > best {
					best = cell.HTTPReqRate
				}
			}
			val := 0.0
			if c, ok := byGW[gw][load]; ok && c.Verdict == "PASS" && best > 0 {
				val = roundTo(c.HTTPReqRate/best*100, 1)
			}
			s.Data = append(s.Data, val)
		}
		series = append(series, s)
	}
	return labels, series
}

// BuildTabs produces one PolicyTab per policy that has any cell of
// any verdict. loads controls the sub-section order inside each tab
// (only loads with at least one cell across the gateways are kept).
func BuildTabs(idx *Index, loads []string) []PolicyTab {
	tabs := make([]PolicyTab, 0, len(PolicyOrder))
	for _, policy := range PolicyOrder {
		byGW, ok := idx.Buckets[policy]
		if !ok {
			continue
		}
		tab := PolicyTab{
			Policy: policy,
			Meta:   PolicyDescriptions[policy],
		}
		for _, load := range loads {
			lg, hasData := buildLoadGroup(policy, byGW, load)
			if !hasData {
				continue
			}
			tab.Loads = append(tab.Loads, lg)
			for _, c := range lg.Cells {
				if c.Unstable {
					tab.HasUnstable = true
				}
			}
		}
		tab.ParityLine = parityLine(byGW, loads)
		if len(tab.Loads) > 0 {
			tabs = append(tabs, tab)
		}
	}
	return tabs
}

func buildLoadGroup(policy string, byGW map[string]map[string]Cell, load string) (LoadGroup, bool) {
	pass := make([]Cell, 0, len(byGW))
	excluded := make([]Cell, 0)
	for gw, byLoad := range byGW {
		cell, ok := byLoad[load]
		if !ok {
			continue
		}
		switch cell.Verdict {
		case "PASS":
			cell.Gateway = gw
			pass = append(pass, cell)
		case "EXCLUDED":
			cell.Gateway = gw
			excluded = append(excluded, cell)
		}
	}
	if len(pass) == 0 && len(excluded) == 0 {
		return LoadGroup{}, false
	}

	sort.SliceStable(pass, func(i, j int) bool { return pass[i].HTTPReqRate > pass[j].HTTPReqRate })

	g := LoadGroup{
		Load:     load,
		Meta:     LoadDescriptions[load],
		Cells:    pass,
		Excluded: excluded,
	}

	g.ChartLabels = make([]string, len(pass))
	g.ChartRPS = make([]float64, len(pass))
	g.ChartP50 = make([]float64, len(pass))
	g.ChartP95 = make([]float64, len(pass))
	g.ChartColors = make([]string, len(pass))
	for i, c := range pass {
		g.ChartLabels[i] = c.Gateway
		g.ChartRPS[i] = roundTo(c.HTTPReqRate, 1)
		g.ChartColors[i] = GatewayColors[c.Gateway]
		if c.TimingBroken {
			g.ChartP50[i] = math.NaN()
			g.ChartP95[i] = math.NaN()
		} else {
			g.ChartP50[i] = roundTo(c.HTTPReqDurationP50, 3)
			g.ChartP95[i] = roundTo(c.HTTPReqDurationP95, 3)
		}
	}

	if len(pass) > 0 {
		w := pass[0]
		g.RPSWinner = &w
	}
	for _, c := range pass {
		if c.TimingBroken {
			continue
		}
		if g.LatWinner == nil || c.HTTPReqDurationP95 < g.LatWinner.HTTPReqDurationP95 {
			cc := c
			g.LatWinner = &cc
		}
	}

	_ = policy // reserved for future per-policy chart styling
	return g, true
}

// parityLine returns "All N PASS" / "X PASS · Y EXCLUDED · Z FAIL"
// depending on what we saw across the load profiles for this policy.
// Counts each (gateway, load) pair once.
func parityLine(byGW map[string]map[string]Cell, loads []string) string {
	var pass, excluded, failed, other int
	for _, byLoad := range byGW {
		for _, load := range loads {
			cell, ok := byLoad[load]
			if !ok {
				continue
			}
			switch cell.Verdict {
			case "PASS":
				pass++
			case "EXCLUDED":
				excluded++
			case "FAIL", "TIMEOUT", "CRASHED":
				failed++
			default:
				other++
			}
		}
	}
	switch {
	case pass > 0 && excluded == 0 && failed == 0 && other == 0:
		return fmt.Sprintf("All %d PASS", pass)
	default:
		parts := []string{}
		if pass > 0 {
			parts = append(parts, fmt.Sprintf("%d PASS", pass))
		}
		if excluded > 0 {
			parts = append(parts, fmt.Sprintf("%d EXCLUDED", excluded))
		}
		if failed > 0 {
			parts = append(parts, fmt.Sprintf("%d FAIL", failed))
		}
		if other > 0 {
			parts = append(parts, fmt.Sprintf("%d OTHER", other))
		}
		if len(parts) == 0 {
			return "no data"
		}
		return strings.Join(parts, " · ")
	}
}

// BuildFooter rolls the per-cell verdicts into the footer string.
func BuildFooter(idx *Index) Footer {
	f := Footer{}
	seenRuns := make(map[string]struct{})
	for _, c := range idx.All {
		switch c.Verdict {
		case "PASS":
			f.PassCount++
		case "EXCLUDED":
			f.ExcludedCount++
		case "FAIL", "TIMEOUT", "CRASHED":
			f.FailCount++
		default:
			f.OtherCount++
		}
		if c.RunID != "" {
			seenRuns[c.RunID] = struct{}{}
		}
	}
	for r := range seenRuns {
		f.RunIDs = append(f.RunIDs, r)
	}
	sort.Strings(f.RunIDs)
	return f
}

// BuildChartDataJSON turns every tab/loadGroup into a JS-friendly
// shape: { policy: { load: { labels, rps, p50, p95, colors } } }.
// NaN latencies are emitted as JSON null so Chart.js draws a gap.
func BuildChartDataJSON(tabs []PolicyTab) (string, error) {
	type group struct {
		Labels []string  `json:"labels"`
		RPS    []float64 `json:"rps"`
		P50    []*float64 `json:"p50"`
		P95    []*float64 `json:"p95"`
		Colors []string  `json:"colors"`
	}
	out := make(map[string]map[string]group)
	for _, t := range tabs {
		entry := make(map[string]group)
		for _, lg := range t.Loads {
			p50 := nullable(lg.ChartP50)
			p95 := nullable(lg.ChartP95)
			entry[lg.Load] = group{
				Labels: lg.ChartLabels,
				RPS:    lg.ChartRPS,
				P50:    p50,
				P95:    p95,
				Colors: lg.ChartColors,
			}
		}
		out[t.Policy] = entry
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// nullable converts NaN entries to JSON null (via *float64 pointer).
func nullable(in []float64) []*float64 {
	out := make([]*float64, len(in))
	for i, v := range in {
		if math.IsNaN(v) || math.IsInf(v, 0) {
			out[i] = nil
			continue
		}
		vv := v
		out[i] = &vv
	}
	return out
}

// gatewaysIn returns every gateway that appears in the index, sorted
// by GatewayStack canonical order (nginx first, then alphabetic for
// any unknown extras).
func gatewaysIn(idx *Index) []string {
	seen := map[string]struct{}{}
	for _, byGW := range idx.Buckets {
		for gw := range byGW {
			seen[gw] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for gw := range seen {
		out = append(out, gw)
	}
	rank := indexedSlice(orderedGateways())
	sort.SliceStable(out, func(i, j int) bool {
		ri, oi := rank[out[i]]
		rj, oj := rank[out[j]]
		switch {
		case oi && oj:
			return ri < rj
		case oi:
			return true
		case oj:
			return false
		default:
			return out[i] < out[j]
		}
	})
	return out
}

// orderedGateways returns the canonical gateway order — kept inline
// to avoid importing the matrix package (which would introduce a
// cycle if matrix ever needs report types).
func orderedGateways() []string {
	return []string{"nginx", "wallarm", "envoy", "traefik", "kong", "apisix", "tyk", "backend"}
}

func indexedSlice(items []string) map[string]int {
	m := make(map[string]int, len(items))
	for i, v := range items {
		m[v] = i
	}
	return m
}

func roundTo(v float64, places int) float64 {
	shift := math.Pow(10, float64(places))
	return math.Round(v*shift) / shift
}
