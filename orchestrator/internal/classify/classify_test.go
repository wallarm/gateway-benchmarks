package classify

import "testing"

func TestCountersTotalAndRatio(t *testing.T) {
	c := Counters{
		Policy2xx:           100,
		Policy4xxExpected:   50,
		Policy4xxUnexpected: 5,
		Policy5xxUnexpected: 5,
	}
	if got := c.Total(); got != 160 {
		t.Errorf("Total = %d, want 160", got)
	}
	if got := c.UnexpectedRatio(); got < 0.062 || got > 0.063 {
		t.Errorf("UnexpectedRatio = %f, want ~0.0625", got)
	}
	if (Counters{}).UnexpectedRatio() != 0 {
		t.Error("zero counters should yield 0 ratio (no division by zero)")
	}
}

func TestLatencyShapeBroken(t *testing.T) {
	if !(LatencyShape{HTTPReqs: 5000, P50: 0, P95: 0, Max: 0}).IsTimingBroken() {
		t.Error("flat-zero high-traffic latency must classify as broken")
	}
	if (LatencyShape{HTTPReqs: 5000, P50: 1, P95: 0, Max: 0}).IsTimingBroken() {
		t.Error("non-zero P50 should NOT be broken")
	}
	if (LatencyShape{HTTPReqs: 50, P50: 0, P95: 0, Max: 0}).IsTimingBroken() {
		t.Error("low-traffic cell should NOT be flagged broken (no signal)")
	}
}

func TestClassify(t *testing.T) {
	good := Counters{Policy2xx: 1000}
	bad := Counters{Policy2xx: 10, Policy5xxUnexpected: 100}
	yellow := Counters{Policy2xx: 990, Policy5xxUnexpected: 5}
	lat := LatencyShape{HTTPReqs: 1000, P50: 1, P95: 2, Max: 5}

	cases := []struct {
		name     string
		counters Counters
		lat      LatencyShape
		excl     bool
		want     Health
	}{
		{"green", good, lat, false, HealthGreen},
		{"yellow", yellow, lat, false, HealthYellow},
		{"red", bad, lat, false, HealthRed},
		{"excluded", good, lat, true, HealthExcluded},
		{"broken", good, LatencyShape{HTTPReqs: 5000, P50: 0, P95: 0, Max: 0}, false, HealthBroken},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Classify(tc.counters, tc.lat, tc.excl); got != tc.want {
				t.Errorf("Classify(%s) = %s, want %s", tc.name, got, tc.want)
			}
		})
	}
}
