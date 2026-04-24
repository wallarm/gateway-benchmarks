package aggregate

import (
	"math"
	"testing"
)

func TestSplitCellName(t *testing.T) {
	cases := []struct {
		in       string
		policy   string
		load     string
		scenario string
		ok       bool
	}{
		{"p01-vanilla__p1-baseline__s01-vanilla-http", "p01-vanilla", "p1-baseline", "s01-vanilla-http", true},
		{"p12-full-pipeline__p2-sustained__s12-full-pipeline-http",
			"p12-full-pipeline", "p2-sustained", "s12-full-pipeline-http", true},
		{"p01-vanilla__p1-baseline__s01-vanilla-http__rep3",
			"p01-vanilla", "p1-baseline", "s01-vanilla-http", true},
		{"not-a-cell", "", "", "", false},
		{"p01__bad", "", "", "", false},
	}
	for _, c := range cases {
		gotP, gotL, gotS, ok := splitCellName(c.in)
		if ok != c.ok {
			t.Errorf("splitCellName(%q): ok=%v, want %v", c.in, ok, c.ok)
			continue
		}
		if !c.ok {
			continue
		}
		if gotP != c.policy || gotL != c.load || gotS != c.scenario {
			t.Errorf("splitCellName(%q) = (%q,%q,%q), want (%q,%q,%q)",
				c.in, gotP, gotL, gotS, c.policy, c.load, c.scenario)
		}
	}
}

func TestFormatFloat(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "0"},
		{1.5, "1.5"},
		{math.NaN(), "0"},
		{math.Inf(1), "0"},
	}
	for _, c := range cases {
		if got := formatFloat(c.in); got != c.want {
			t.Errorf("formatFloat(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRoundTo(t *testing.T) {
	if got := roundTo(1.23456, 2); got != 1.23 {
		t.Errorf("roundTo(1.23456, 2) = %v, want 1.23", got)
	}
	if got := roundTo(1.235, 2); got != 1.24 {
		t.Errorf("roundTo(1.235, 2) = %v, want 1.24", got)
	}
}
