// Package compare diffs two bench runs against the canonical
// tolerance table (TASK §8, docs/REPRODUCIBILITY.md §Tolerances).
//
// It answers three questions, any of which failing marks the pair
// "not reproducible":
//
//  1. Identity — do the two runs agree on the invariants that *must*
//     be byte-identical (git SHA, seed, matrix shape, image digests)?
//     When either manifest is absent, identity checks are skipped
//     with an INFO note instead of failing the comparison.
//  2. Numeric similarity — for every matched cell, does each metric
//     stay within its configured tolerance (defaults below, override
//     with compare.Tolerances)?
//  3. Ranking stability — for every (policy, load) column, does the
//     top-3 gateway order agree across runs? Policy/load columns that
//     differ produce a RankBreak entry.
//
// Default tolerances (copied verbatim from docs/REPRODUCIBILITY.md):
//
//	RPS                 ±3 %
//	latency p50/p95/p99 ±10 %
//	memory peak/steady  ±5 %
//	CPU %               ±10 %
//	error 5xx absolute  must match
//	error 4xx-expected  must match
//
// The caller decides whether to fail its process — Compare() only
// classifies the result.
package compare

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// Tolerances mirrors the table in docs/REPRODUCIBILITY.md §8. Values
// are *fractions* (0.03 = ±3 %), not percentages.
type Tolerances struct {
	RPS           float64
	LatencyP50    float64
	LatencyP95    float64
	LatencyP99    float64
	MemPeak       float64
	MemSteady     float64
	CPUPct        float64
	ErrorsMustEq  bool // 5xx + 4xx_expected must match exactly
}

// DefaultTolerances is the TASK §8 canonical set. Tests and CI
// should pin this value — production runs can override per-invocation.
func DefaultTolerances() Tolerances {
	return Tolerances{
		RPS:          0.03,
		LatencyP50:   0.10,
		LatencyP95:   0.10,
		LatencyP99:   0.10,
		MemPeak:      0.05,
		MemSteady:    0.05,
		CPUPct:       0.10,
		ErrorsMustEq: true,
	}
}

// CellKey uniquely identifies a cell across runs. It is deliberately
// NOT tied to a specific Repetition — compare is run-level, not
// rep-level, so we collapse repetitions via the mean when more than
// one rep per cell exists (rare; only when --reps N > 1).
type CellKey struct {
	Gateway  string
	Policy   string
	Load     string
	Scenario string
}

func (k CellKey) String() string {
	return fmt.Sprintf("%s/%s/%s/%s", k.Gateway, k.Policy, k.Load, k.Scenario)
}

// MetricDelta is one observation pair (runA → runB) for a single
// numeric metric, with the tolerance that applies and whether the
// pair is within that tolerance.
type MetricDelta struct {
	Name        string
	ValueA      float64
	ValueB      float64
	AbsDiff     float64
	RelDiff     float64  // |A-B| / max(|A|,|B|,eps)
	Tolerance   float64
	WithinLimit bool
	Unit        string
}

// CellDiff bundles every metric comparison for one cell.
type CellDiff struct {
	Key       CellKey
	OnlyInA   bool
	OnlyInB   bool
	VerdictA  string
	VerdictB  string
	HealthA   string
	HealthB   string
	Metrics   []MetricDelta
	ErrorMis  []ErrorMismatch
	WithinAll bool
}

// ErrorMismatch records a hard-equality break on 5xx / 4xx_expected /
// 4xx_unexpected — these have to match exactly under the TASK §8
// tolerance of 0 per million.
type ErrorMismatch struct {
	Name   string
	CountA int64
	CountB int64
}

// IdentityCheck records whether a manifest-level invariant matched.
// Passing Missing = true means the check was skipped because the
// underlying manifest(s) were not available.
type IdentityCheck struct {
	Name    string
	Match   bool
	Missing bool
	Note    string
	ValueA  string
	ValueB  string
}

// RankBreak captures a per-column rank-agreement failure. The
// TopN field carries how many positions were checked (default 3).
type RankBreak struct {
	Policy   string
	Load     string
	Scenario string
	TopN     int
	OrderA   []string
	OrderB   []string
}

// Summary is the aggregate verdict across Identity + Numeric + Rank.
// ExitCode follows the shell convention: 0 = all good, 1 = soft break
// (INFO / WARN), 2 = hard break (identity or numeric divergence, or
// rank instability).
type Summary struct {
	Identity       []IdentityCheck
	Diffs          []CellDiff
	RankBreaks     []RankBreak
	CellsMatched   int
	CellsOnlyInA   int
	CellsOnlyInB   int
	CellsDivergent int
	Identical      bool
	WithinToler    bool
	RankStable     bool
	Tolerances     Tolerances
}

// ExitCode is the process exit code Compare asks its caller to
// propagate.
func (s *Summary) ExitCode() int {
	switch {
	case !s.Identical, !s.WithinToler, !s.RankStable:
		return 2
	case s.CellsOnlyInA > 0, s.CellsOnlyInB > 0:
		return 1
	default:
		return 0
	}
}

// ManifestView is the narrow projection of manifest.json we need for
// identity checks. The full schema lives in internal/manifest but we
// intentionally avoid importing it here so `bench compare-runs` can
// run against historical runs that predate the Phase 6 manifest.
type ManifestView struct {
	SchemaVersion string         `json:"schema_version"`
	RunID         string         `json:"run_id"`
	Mode          string         `json:"mode"`
	Seed          int64          `json:"seed"`
	Repetitions   int            `json:"repetitions"`
	SelectedRows  []string       `json:"selected_rows"`
	Git           map[string]any `json:"git"`
	K6            map[string]any `json:"k6"`
	Gateways      []struct {
		Name   string `json:"name"`
		Image  string `json:"image"`
		Digest string `json:"digest"`
	} `json:"gateways"`
}

// Input describes one side of the comparison.
type Input struct {
	Label    string // e.g. "run-A" — only used in output
	Cells    []aggregate.Cell
	Manifest *ManifestView // optional; identity is skipped if nil
}

// Compare is the entry point: takes run A and run B (plus tolerances)
// and returns a populated Summary. The inputs themselves are not
// mutated; the caller owns them.
func Compare(a, b Input, tol Tolerances) *Summary {
	s := &Summary{
		Tolerances:  tol,
		Identical:   true,
		WithinToler: true,
		RankStable:  true,
	}

	s.Identity = identityChecks(a.Manifest, b.Manifest)
	for _, ic := range s.Identity {
		if !ic.Match && !ic.Missing {
			s.Identical = false
		}
	}

	s.Diffs = cellDiffs(a.Cells, b.Cells, tol)
	for _, d := range s.Diffs {
		switch {
		case d.OnlyInA:
			s.CellsOnlyInA++
		case d.OnlyInB:
			s.CellsOnlyInB++
		default:
			s.CellsMatched++
			if !d.WithinAll {
				s.CellsDivergent++
				s.WithinToler = false
			}
		}
	}

	s.RankBreaks = rankStability(a.Cells, b.Cells, 3)
	if len(s.RankBreaks) > 0 {
		s.RankStable = false
	}

	return s
}

// ------------------------------------------------------------------
// internals

func identityChecks(a, b *ManifestView) []IdentityCheck {
	if a == nil || b == nil {
		return []IdentityCheck{{
			Name:    "manifest",
			Match:   true,
			Missing: true,
			Note:    "manifest.json missing on one or both runs — skipping identity checks",
		}}
	}

	out := []IdentityCheck{}

	gitA, _ := a.Git["sha"].(string)
	gitB, _ := b.Git["sha"].(string)
	out = append(out, IdentityCheck{
		Name:   "git_sha",
		Match:  gitA == gitB && gitA != "",
		ValueA: gitA, ValueB: gitB,
		Note: "source revision at run time",
	})

	out = append(out, IdentityCheck{
		Name:   "seed",
		Match:  a.Seed == b.Seed,
		ValueA: fmt.Sprintf("%d", a.Seed), ValueB: fmt.Sprintf("%d", b.Seed),
		Note: "RNG seed forwarded to k6",
	})

	digA, _ := a.K6["digest"].(string)
	digB, _ := b.K6["digest"].(string)
	out = append(out, IdentityCheck{
		Name:   "k6_digest",
		Match:  digA == digB && digA != "",
		ValueA: digA, ValueB: digB,
		Note: "grafana/k6 image pinned by digest",
	})

	out = append(out, IdentityCheck{
		Name:   "selected_rows",
		Match:  stringSlicesEqualSorted(a.SelectedRows, b.SelectedRows),
		ValueA: fmt.Sprintf("%d rows", len(a.SelectedRows)),
		ValueB: fmt.Sprintf("%d rows", len(b.SelectedRows)),
		Note:   "matrix shape (gateway/policy/load/scenario tuples)",
	})

	out = append(out, IdentityCheck{
		Name:   "gateway_digests",
		Match:  gatewayDigestsEqual(a, b),
		ValueA: fmt.Sprintf("%d gateways", len(a.Gateways)),
		ValueB: fmt.Sprintf("%d gateways", len(b.Gateways)),
		Note:   "per-gateway image digest",
	})

	return out
}

func gatewayDigestsEqual(a, b *ManifestView) bool {
	if len(a.Gateways) != len(b.Gateways) {
		return false
	}
	m := make(map[string]string, len(a.Gateways))
	for _, g := range a.Gateways {
		m[g.Name] = g.Digest
	}
	for _, g := range b.Gateways {
		if m[g.Name] != g.Digest {
			return false
		}
	}
	return true
}

func stringSlicesEqualSorted(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	aa := append([]string{}, a...)
	bb := append([]string{}, b...)
	sort.Strings(aa)
	sort.Strings(bb)
	for i := range aa {
		if aa[i] != bb[i] {
			return false
		}
	}
	return true
}

// cellDiffs walks both cell lists and emits one CellDiff per unique
// key, matching on (gateway, policy, load, scenario). Repetitions
// inside the same run are averaged (rare case).
func cellDiffs(a, b []aggregate.Cell, tol Tolerances) []CellDiff {
	aByKey := indexByKey(a)
	bByKey := indexByKey(b)

	keys := make(map[CellKey]struct{}, len(aByKey)+len(bByKey))
	for k := range aByKey {
		keys[k] = struct{}{}
	}
	for k := range bByKey {
		keys[k] = struct{}{}
	}

	ordered := make([]CellKey, 0, len(keys))
	for k := range keys {
		ordered = append(ordered, k)
	}
	sort.Slice(ordered, func(i, j int) bool {
		return ordered[i].String() < ordered[j].String()
	})

	out := make([]CellDiff, 0, len(ordered))
	for _, k := range ordered {
		ca, okA := aByKey[k]
		cb, okB := bByKey[k]
		switch {
		case okA && !okB:
			out = append(out, CellDiff{Key: k, OnlyInA: true, VerdictA: ca.Verdict, HealthA: string(ca.Health)})
		case !okA && okB:
			out = append(out, CellDiff{Key: k, OnlyInB: true, VerdictB: cb.Verdict, HealthB: string(cb.Health)})
		default:
			out = append(out, diffCell(k, ca, cb, tol))
		}
	}
	return out
}

func indexByKey(cells []aggregate.Cell) map[CellKey]aggregate.Cell {
	type agg struct {
		sum   aggregate.Cell
		count int
	}
	acc := make(map[CellKey]*agg, len(cells))
	for _, c := range cells {
		k := CellKey{Gateway: c.Gateway, Policy: c.Policy, Load: c.Load, Scenario: c.Scenario}
		cur := acc[k]
		if cur == nil {
			cur = &agg{}
			acc[k] = cur
		}
		accumulate(&cur.sum, c)
		cur.count++
	}
	out := make(map[CellKey]aggregate.Cell, len(acc))
	for k, v := range acc {
		out[k] = finalise(v.sum, v.count)
	}
	return out
}

// accumulate sums the fields we average across repetitions. Counters
// (HTTPReqs, error tallies) are also summed because k6 runs are
// independent; we average them after the fact.
func accumulate(dst *aggregate.Cell, src aggregate.Cell) {
	if dst.Gateway == "" {
		dst.Gateway = src.Gateway
		dst.Policy = src.Policy
		dst.Scenario = src.Scenario
		dst.Load = src.Load
		dst.RunID = src.RunID
		dst.Verdict = src.Verdict
		dst.ParityStatus = src.ParityStatus
		dst.Health = src.Health
	}
	dst.HTTPReqs += src.HTTPReqs
	dst.HTTPReqRate += src.HTTPReqRate
	dst.IterDurationAvgMs += src.IterDurationAvgMs
	dst.HTTPReqDurationP50 += src.HTTPReqDurationP50
	dst.HTTPReqDurationP90 += src.HTTPReqDurationP90
	dst.HTTPReqDurationP95 += src.HTTPReqDurationP95
	dst.HTTPReqDurationP99 += src.HTTPReqDurationP99
	dst.HTTPReqDurationMax += src.HTTPReqDurationMax
	dst.HTTPReqFailedRate += src.HTTPReqFailedRate
	dst.Policy2xx += src.Policy2xx
	dst.Policy4xxExpected += src.Policy4xxExpected
	dst.Policy4xxUnexpected += src.Policy4xxUnexpected
	dst.Policy5xxUnexpected += src.Policy5xxUnexpected
	dst.ChecksTotal += src.ChecksTotal
	dst.ChecksPasses += src.ChecksPasses
	dst.ChecksFails += src.ChecksFails
	if src.MemRSSPeakBytes > dst.MemRSSPeakBytes {
		dst.MemRSSPeakBytes = src.MemRSSPeakBytes
	}
	dst.MemRSSSteadyBytes += src.MemRSSSteadyBytes
	if src.CPUPctPeak > dst.CPUPctPeak {
		dst.CPUPctPeak = src.CPUPctPeak
	}
	dst.CPUPctSteady += src.CPUPctSteady
	if src.TimingBroken {
		dst.TimingBroken = true
	}
}

func finalise(c aggregate.Cell, n int) aggregate.Cell {
	if n <= 1 {
		return c
	}
	f := float64(n)
	c.HTTPReqRate /= f
	c.IterDurationAvgMs /= f
	c.HTTPReqDurationP50 /= f
	c.HTTPReqDurationP90 /= f
	c.HTTPReqDurationP95 /= f
	c.HTTPReqDurationP99 /= f
	c.HTTPReqDurationMax /= f
	c.HTTPReqFailedRate /= f
	c.MemRSSSteadyBytes = int64(float64(c.MemRSSSteadyBytes) / f)
	c.CPUPctSteady /= f
	return c
}

// diffCell emits the MetricDelta set for one matched cell. Health /
// Verdict mismatches propagate to top-level but are not "within
// tolerance" metrics on their own.
func diffCell(k CellKey, a, b aggregate.Cell, tol Tolerances) CellDiff {
	d := CellDiff{
		Key:       k,
		VerdictA:  a.Verdict,
		VerdictB:  b.Verdict,
		HealthA:   string(a.Health),
		HealthB:   string(b.Health),
		WithinAll: true,
	}

	if a.Verdict != b.Verdict {
		d.WithinAll = false
	}

	push := func(name, unit string, va, vb, tolerance float64) {
		m := metricDelta(name, unit, va, vb, tolerance)
		d.Metrics = append(d.Metrics, m)
		if !m.WithinLimit {
			d.WithinAll = false
		}
	}

	push("rps", "rps", a.HTTPReqRate, b.HTTPReqRate, tol.RPS)
	push("p50_ms", "ms", a.HTTPReqDurationP50, b.HTTPReqDurationP50, tol.LatencyP50)
	push("p95_ms", "ms", a.HTTPReqDurationP95, b.HTTPReqDurationP95, tol.LatencyP95)
	push("p99_ms", "ms", a.HTTPReqDurationP99, b.HTTPReqDurationP99, tol.LatencyP99)
	push("mem_peak", "bytes", float64(a.MemRSSPeakBytes), float64(b.MemRSSPeakBytes), tol.MemPeak)
	push("mem_steady", "bytes", float64(a.MemRSSSteadyBytes), float64(b.MemRSSSteadyBytes), tol.MemSteady)
	push("cpu_peak", "%", a.CPUPctPeak, b.CPUPctPeak, tol.CPUPct)
	push("cpu_steady", "%", a.CPUPctSteady, b.CPUPctSteady, tol.CPUPct)

	if tol.ErrorsMustEq {
		if a.Policy5xxUnexpected != b.Policy5xxUnexpected {
			d.ErrorMis = append(d.ErrorMis, ErrorMismatch{"policy_5xx_unexpected", a.Policy5xxUnexpected, b.Policy5xxUnexpected})
			d.WithinAll = false
		}
		if a.Policy4xxExpected != b.Policy4xxExpected {
			d.ErrorMis = append(d.ErrorMis, ErrorMismatch{"policy_4xx_expected", a.Policy4xxExpected, b.Policy4xxExpected})
			d.WithinAll = false
		}
	}

	return d
}

// metricDelta compares two observations against a relative tolerance.
// When both sides are zero (common for EXCLUDED / timing-broken
// cells) the pair is trivially within tolerance.
func metricDelta(name, unit string, a, b, tol float64) MetricDelta {
	abs := math.Abs(a - b)
	denom := math.Max(math.Max(math.Abs(a), math.Abs(b)), 1e-12)
	rel := abs / denom

	within := rel <= tol
	if a == 0 && b == 0 {
		within = true
		rel = 0
	}

	return MetricDelta{
		Name:        name,
		ValueA:      a,
		ValueB:      b,
		AbsDiff:     abs,
		RelDiff:     rel,
		Tolerance:   tol,
		WithinLimit: within,
		Unit:        unit,
	}
}

// rankStability computes top-N gateway rank per (policy, load, scenario)
// column on each run and flags any column where the two orderings
// diverge. Only cells with Verdict=PASS and HTTPReqRate > 0 vote.
func rankStability(a, b []aggregate.Cell, topN int) []RankBreak {
	ax := byColumn(a)
	bx := byColumn(b)

	cols := make(map[columnKey]struct{}, len(ax)+len(bx))
	for k := range ax {
		cols[k] = struct{}{}
	}
	for k := range bx {
		cols[k] = struct{}{}
	}

	ordered := make([]columnKey, 0, len(cols))
	for k := range cols {
		ordered = append(ordered, k)
	}
	sort.Slice(ordered, func(i, j int) bool {
		if ordered[i].Policy != ordered[j].Policy {
			return ordered[i].Policy < ordered[j].Policy
		}
		if ordered[i].Load != ordered[j].Load {
			return ordered[i].Load < ordered[j].Load
		}
		return ordered[i].Scenario < ordered[j].Scenario
	})

	var breaks []RankBreak
	for _, c := range ordered {
		orderA := rankOrder(ax[c], topN)
		orderB := rankOrder(bx[c], topN)
		if !stringSlicesEqual(orderA, orderB) {
			breaks = append(breaks, RankBreak{
				Policy:   c.Policy,
				Load:     c.Load,
				Scenario: c.Scenario,
				TopN:     topN,
				OrderA:   orderA,
				OrderB:   orderB,
			})
		}
	}
	return breaks
}

type columnKey struct {
	Policy   string
	Load     string
	Scenario string
}

func byColumn(cells []aggregate.Cell) map[columnKey][]aggregate.Cell {
	out := make(map[columnKey][]aggregate.Cell, 16)
	for _, c := range cells {
		if c.Verdict != "PASS" || c.HTTPReqRate <= 0 {
			continue
		}
		k := columnKey{Policy: c.Policy, Load: c.Load, Scenario: c.Scenario}
		out[k] = append(out[k], c)
	}
	return out
}

func rankOrder(cells []aggregate.Cell, topN int) []string {
	if len(cells) == 0 {
		return nil
	}
	cp := make([]aggregate.Cell, len(cells))
	copy(cp, cells)
	sort.SliceStable(cp, func(i, j int) bool {
		return cp[i].HTTPReqRate > cp[j].HTTPReqRate
	})
	if topN > len(cp) {
		topN = len(cp)
	}
	out := make([]string, 0, topN)
	for i := 0; i < topN; i++ {
		out = append(out, cp[i].Gateway)
	}
	return out
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// RenderText is the human-readable report `bench compare-runs` prints
// to stdout. It is deterministic (stable ordering) so diff tools can
// consume the text directly.
func RenderText(s *Summary, labelA, labelB string) string {
	var sb strings.Builder

	fmt.Fprintf(&sb, "compare-runs: %s  ↔  %s\n", labelA, labelB)
	fmt.Fprintln(&sb, strings.Repeat("─", 72))

	sb.WriteString("identity\n")
	for _, ic := range s.Identity {
		mark := "✓"
		switch {
		case ic.Missing:
			mark = "·"
		case !ic.Match:
			mark = "✗"
		}
		if ic.Missing {
			fmt.Fprintf(&sb, "  %s %-18s SKIP — %s\n", mark, ic.Name, ic.Note)
			continue
		}
		if ic.Match {
			fmt.Fprintf(&sb, "  %s %-18s %s\n", mark, ic.Name, firstNonEmpty(ic.ValueA, "ok"))
		} else {
			fmt.Fprintf(&sb, "  %s %-18s A=%q  B=%q\n", mark, ic.Name, ic.ValueA, ic.ValueB)
		}
	}
	fmt.Fprintln(&sb)

	fmt.Fprintf(&sb, "cells: matched=%d  only-in-A=%d  only-in-B=%d  divergent=%d\n",
		s.CellsMatched, s.CellsOnlyInA, s.CellsOnlyInB, s.CellsDivergent)

	for _, d := range s.Diffs {
		if d.OnlyInA {
			fmt.Fprintf(&sb, "  · %s  ONLY-IN-A (verdict=%s)\n", d.Key, d.VerdictA)
			continue
		}
		if d.OnlyInB {
			fmt.Fprintf(&sb, "  · %s  ONLY-IN-B (verdict=%s)\n", d.Key, d.VerdictB)
			continue
		}
		if d.WithinAll {
			continue
		}
		fmt.Fprintf(&sb, "  ✗ %s  verdictA=%s verdictB=%s\n", d.Key, d.VerdictA, d.VerdictB)
		for _, m := range d.Metrics {
			if m.WithinLimit {
				continue
			}
			fmt.Fprintf(&sb, "      %-12s A=%s B=%s  rel=%.2f%% (tol=±%.2f%%)\n",
				m.Name, fmtVal(m.ValueA, m.Unit), fmtVal(m.ValueB, m.Unit),
				m.RelDiff*100, m.Tolerance*100)
		}
		for _, e := range d.ErrorMis {
			fmt.Fprintf(&sb, "      %-12s A=%d B=%d  (tolerance=0, must match)\n",
				e.Name, e.CountA, e.CountB)
		}
	}
	fmt.Fprintln(&sb)

	if len(s.RankBreaks) == 0 {
		fmt.Fprintln(&sb, "rank stability: top-3 agrees on every column ✓")
	} else {
		fmt.Fprintf(&sb, "rank stability: %d column(s) disagree ✗\n", len(s.RankBreaks))
		for _, rb := range s.RankBreaks {
			fmt.Fprintf(&sb, "  %s / %s / %s\n", rb.Policy, rb.Load, rb.Scenario)
			fmt.Fprintf(&sb, "    A: %s\n", strings.Join(rb.OrderA, " > "))
			fmt.Fprintf(&sb, "    B: %s\n", strings.Join(rb.OrderB, " > "))
		}
	}
	fmt.Fprintln(&sb)

	verdict := "REPRODUCIBLE"
	code := s.ExitCode()
	switch code {
	case 1:
		verdict = "SOFT DIFF (only-in-A or only-in-B cells)"
	case 2:
		switch {
		case !s.Identical:
			verdict = "NOT REPRODUCIBLE — identity mismatch"
		case !s.WithinToler:
			verdict = "NOT REPRODUCIBLE — metric outside tolerance"
		case !s.RankStable:
			verdict = "NOT REPRODUCIBLE — top-3 rank unstable"
		}
	}
	fmt.Fprintf(&sb, "verdict: %s  (exit=%d)\n", verdict, code)
	return sb.String()
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func fmtVal(v float64, unit string) string {
	switch unit {
	case "rps":
		return fmt.Sprintf("%.2frps", v)
	case "ms":
		return fmt.Sprintf("%.3fms", v)
	case "bytes":
		return fmtBytes(int64(v))
	case "%":
		return fmt.Sprintf("%.2f%%", v)
	default:
		return fmt.Sprintf("%.3f", v)
	}
}

func fmtBytes(b int64) string {
	const k = 1024
	if b < k {
		return fmt.Sprintf("%dB", b)
	}
	units := []string{"KiB", "MiB", "GiB", "TiB"}
	n := float64(b) / k
	u := 0
	for n >= k && u < len(units)-1 {
		n /= k
		u++
	}
	return fmt.Sprintf("%.2f%s", n, units[u])
}
