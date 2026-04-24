package report

import "testing"

func TestCommafy(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"0", "0"},
		{"42", "42"},
		{"999", "999"},
		{"1000", "1,000"},
		{"1234567", "1,234,567"},
		{"-1234567", "-1,234,567"},
		{"1234.5", "1,234.5"},
		{"-1234.567", "-1,234.567"},
	}
	for _, tc := range cases {
		if got := commafy(tc.in); got != tc.want {
			t.Fatalf("commafy(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestFmtBytes(t *testing.T) {
	cases := []struct {
		in   int64
		want string
	}{
		{0, "—"},
		{1024 * 1024, "~1 MB"},
		{int64(150 * 1024 * 1024), "~150 MB"},
		{int64(1.5 * 1024 * 1024 * 1024), "~1.5 GB"},
	}
	for _, tc := range cases {
		if got := fmtBytes(tc.in); got != tc.want {
			t.Fatalf("fmtBytes(%d) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestShortHelpers(t *testing.T) {
	if got := shortSHA("142744e37ca4135d142cd0e58e337cc10568aa2b"); got != "142744e" {
		t.Fatalf("shortSHA: got %q", got)
	}
	if got := shortSHA("abc"); got != "abc" {
		t.Fatalf("shortSHA short: got %q", got)
	}
	if got := shortDigest("sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f"); len(got) >= 30 {
		t.Fatalf("shortDigest too long: %s", got)
	}
}

func TestRankSymbol(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{0, "🥇"},
		{1, "🥈"},
		{2, "🥉"},
		{3, "#4"},
		{99, "#100"},
	}
	for _, tc := range cases {
		if got := rankSymbol(tc.in); got != tc.want {
			t.Fatalf("rankSymbol(%d) = %q want %q", tc.in, got, tc.want)
		}
	}
}
