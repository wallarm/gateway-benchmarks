// Package classify turns raw k6 counters into a 4-bucket
// pass/fail picture per cell. It mirrors the rules baked into
// docs/REPORT.md § "Verdict colour rules" so the HTML report and
// the orchestrator agree on what counts as healthy.
//
// Inputs come straight from a parsed k6-summary.json — we don't
// re-derive them, just classify.
package classify

// Counters is the raw 4-bucket breakdown emitted by every k6
// scenario via custom Counter metrics (k6/lib/checks.js).
type Counters struct {
	Policy2xx           int64
	Policy4xxExpected   int64
	Policy4xxUnexpected int64
	Policy5xxUnexpected int64
}

// Total is the sum of all four buckets.
func (c Counters) Total() int64 {
	return c.Policy2xx + c.Policy4xxExpected + c.Policy4xxUnexpected + c.Policy5xxUnexpected
}

// UnexpectedRatio returns (4xx_unexpected + 5xx_unexpected) / total
// in the [0,1] range. Returns 0 when total is 0 (no traffic).
func (c Counters) UnexpectedRatio() float64 {
	t := c.Total()
	if t == 0 {
		return 0
	}
	return float64(c.Policy4xxUnexpected+c.Policy5xxUnexpected) / float64(t)
}

// Health is the per-cell colour bucket.
type Health string

const (
	HealthGreen   Health = "GREEN"   // unexpected ratio < 0.1 % AND no broken timing
	HealthYellow  Health = "YELLOW"  // 0.1 % ≤ ratio < 5 %  (partial outage, still ranked)
	HealthRed     Health = "RED"     // ratio ≥ 5 %        (effectively broken under load)
	HealthBroken  Health = "BROKEN"  // timing metrics all zero (e.g. Tyk instrumentation gap)
	HealthExcluded Health = "EXCLUDED"
)

// LatencyShape is the minimal latency signal used for the BROKEN
// detection — when p50, p95 and max are all zero AND the cell sent
// thousands of requests, the timing channel is broken.
type LatencyShape struct {
	HTTPReqs int64
	P50, P95, Max float64
}

// IsTimingBroken returns true when the cell emitted traffic but k6
// recorded a flat-zero duration distribution. Mirrors the heuristic
// in scripts/render-html-report.py § "timing_broken".
func (l LatencyShape) IsTimingBroken() bool {
	return l.HTTPReqs > 100 && l.P50 == 0 && l.P95 == 0 && l.Max == 0
}

// Classify returns the cell colour. Order matters — broken timing
// trumps the ratio check.
func Classify(counters Counters, lat LatencyShape, excluded bool) Health {
	if excluded {
		return HealthExcluded
	}
	if lat.IsTimingBroken() {
		return HealthBroken
	}
	r := counters.UnexpectedRatio()
	switch {
	case r >= 0.05:
		return HealthRed
	case r >= 0.001:
		return HealthYellow
	default:
		return HealthGreen
	}
}
