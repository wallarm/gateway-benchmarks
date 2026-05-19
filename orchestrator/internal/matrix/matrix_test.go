package matrix

import (
	"reflect"
	"testing"
)

func TestParseCSV(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"a", []string{"a"}},
		{"a,b,c", []string{"a", "b", "c"}},
		{" a , b ,c ", []string{"a", "b", "c"}},
		{"a,a,b", []string{"a", "b"}},
		{",,", nil},
	}
	for _, c := range cases {
		got := ParseCSV(c.in)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("ParseCSV(%q) = %v, want %v", c.in, got, c.want)
		}
	}
}

func TestScenarioFor(t *testing.T) {
	cases := map[string]string{
		"p01-vanilla":          "s01-vanilla-http",
		"p03-jwks-rs256-basic": "s03-jwks-rs256-basic-http",
		"p12-full-pipeline":    "s12-full-pipeline-http",
		"weird":                "weird", // no `p` prefix → unchanged
	}
	for in, want := range cases {
		if got := ScenarioFor(in); got != want {
			t.Errorf("ScenarioFor(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestResolveAlias(t *testing.T) {
	if got := ResolveAlias("gateways", "all"); len(got) != len(CanonicalGateways) {
		t.Errorf("gateways/all: want %d, got %d", len(CanonicalGateways), len(got))
	}
	if got := ResolveAlias("policies", "all"); len(got) != 12 {
		t.Errorf("policies/all: want 12, got %d", len(got))
	}
	if got := ResolveAlias("loads", "http"); !reflect.DeepEqual(got, CanonicalLoads) {
		t.Errorf("loads/http: want %v, got %v", CanonicalLoads, got)
	}
	if got := ResolveAlias("loads", "paced"); len(got) != 4 {
		t.Errorf("loads/paced: want 4, got %d", len(got))
	}
	if got := ResolveAlias("loads", "all"); len(got) != 8 {
		t.Errorf("loads/all: want 8 (4 closed-loop + 4 paced), got %d", len(got))
	}
	if got := ResolveAlias("unknown", "anything"); got != nil {
		t.Errorf("unknown kind should return nil")
	}
}

func TestSelectionExpand(t *testing.T) {
	sel := Selection{
		Gateways: []string{"nginx", "kong"},
		Policies: []string{"p01-vanilla", "p02-jwt"},
		Loads:    []string{"p1-baseline", "p2-sustained"},
	}
	cells, err := sel.Expand()
	if err != nil {
		t.Fatal(err)
	}
	want := 2 * 2 * 2
	if len(cells) != want {
		t.Fatalf("expand: want %d cells, got %d", want, len(cells))
	}
	// First cell should be (nginx, p01, p1-baseline, s01-...)
	got := cells[0]
	if got.Gateway != "nginx" || got.Policy != "p01-vanilla" ||
		got.Load != "p1-baseline" || got.Scenario != "s01-vanilla-http" {
		t.Errorf("first cell unexpected: %+v", got)
	}
}

func TestCanonicalReportCells(t *testing.T) {
	cells, err := CanonicalReportCells(
		[]string{"nginx", "kong"},
		[]string{"p1-baseline", "p2-sustained"},
		1,
	)
	if err != nil {
		t.Fatal(err)
	}
	want := 2 * 13 * 2
	if len(cells) != want {
		t.Fatalf("canonical cells: want %d, got %d", want, len(cells))
	}
	for _, c := range cells {
		if c.Policy == "p03-jwks-rs256-basic" {
			t.Fatalf("canonical report matrix must not load supplemental p03: %+v", c)
		}
	}
	var sawS13, sawS14 bool
	for _, c := range cells {
		if c.Scenario == "s13-vanilla-https" {
			sawS13 = true
		}
		if c.Scenario == "s14-full-pipeline-https" {
			sawS14 = true
		}
	}
	if !sawS13 || !sawS14 {
		t.Fatalf("canonical report matrix should include s13/s14; s13=%v s14=%v", sawS13, sawS14)
	}
}

func TestSelectionExpandRejectsBadLoad(t *testing.T) {
	sel := Selection{
		Gateways: []string{"nginx"},
		Policies: []string{"p01-vanilla"},
		Loads:    []string{"bogus-load"},
	}
	if _, err := sel.Expand(); err == nil {
		t.Fatal("expected an error for bogus load profile")
	}
}

func TestSelectionExpandRespectsRepetitions(t *testing.T) {
	sel := Selection{
		Gateways:    []string{"nginx"},
		Policies:    []string{"p01-vanilla"},
		Loads:       []string{"p1-baseline"},
		Repetitions: 3,
	}
	cells, err := sel.Expand()
	if err != nil {
		t.Fatal(err)
	}
	if len(cells) != 3 {
		t.Fatalf("want 3 cells (reps=3), got %d", len(cells))
	}
	for i, c := range cells {
		if c.Repetition != i+1 {
			t.Errorf("cell[%d].Repetition = %d, want %d", i, c.Repetition, i+1)
		}
	}
	if cells[0].ID() != "nginx/p01-vanilla/p1-baseline/s01-vanilla-http" {
		t.Errorf("rep 1 ID should not be suffixed: %s", cells[0].ID())
	}
	if cells[1].ID() != "nginx/p01-vanilla/p1-baseline/s01-vanilla-http#rep2" {
		t.Errorf("rep 2 ID should be suffixed: %s", cells[1].ID())
	}
}

func TestCellOutputDir(t *testing.T) {
	c := Cell{Gateway: "nginx", Policy: "p01-vanilla", Scenario: "s01-vanilla-http", Load: "p1-baseline", Repetition: 1}
	want := "reports/abc/raw/nginx/p01-vanilla__p1-baseline__s01-vanilla-http"
	if got := c.OutputDir("abc"); got != want {
		t.Errorf("OutputDir = %q, want %q", got, want)
	}
	c.Repetition = 3
	want = "reports/abc/raw/nginx/p01-vanilla__p1-baseline__s01-vanilla-http__rep3"
	if got := c.OutputDir("abc"); got != want {
		t.Errorf("OutputDir(rep3) = %q, want %q", got, want)
	}
}

func TestSortStable(t *testing.T) {
	in := []string{"p12-full-pipeline", "p01-vanilla", "p03-jwks-rs256-basic"}
	out := SortStable("policies", in)
	want := []string{"p01-vanilla", "p03-jwks-rs256-basic", "p12-full-pipeline"}
	if !reflect.DeepEqual(out, want) {
		t.Errorf("SortStable policies: got %v, want %v", out, want)
	}
}

func TestParseWallarmImageEnv(t *testing.T) {
	cases := []struct {
		in   string
		want []WallarmVariant
	}{
		{"", nil},
		{"wallarm:branch-main", []WallarmVariant{{Name: "branch-main", Image: "wallarm:branch-main"}}},
		{
			"wallarm:branch-main,wallarm:branch-other",
			[]WallarmVariant{
				{Name: "branch-main", Image: "wallarm:branch-main"},
				{Name: "branch-other", Image: "wallarm:branch-other"},
			},
		},
		{
			// Same tag twice — second gets disambiguated with a -2 suffix.
			"wallarm:main,registry.example/wallarm:main",
			[]WallarmVariant{
				{Name: "main", Image: "wallarm:main"},
				{Name: "main-2", Image: "registry.example/wallarm:main"},
			},
		},
		{
			// Digest-only references: fall back to image name segment.
			"wallarm/api-gateway@sha256:abc",
			[]WallarmVariant{{Name: "api-gateway", Image: "wallarm/api-gateway@sha256:abc"}},
		},
	}
	for _, c := range cases {
		got := ParseWallarmImageEnv(c.in)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("ParseWallarmImageEnv(%q) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

func TestExpandWallarmVariants(t *testing.T) {
	variants := []WallarmVariant{
		{Name: "branch-main", Image: "wallarm:branch-main"},
		{Name: "branch-other", Image: "wallarm:branch-other"},
	}
	got := ExpandWallarmVariants([]string{"nginx", "wallarm", "envoy"}, variants)
	want := []string{"nginx", "wallarm@branch-main", "wallarm@branch-other", "envoy"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ExpandWallarmVariants 2: got %v, want %v", got, want)
	}

	// Single variant: no expansion, legacy column name preserved.
	single := []WallarmVariant{{Name: "main", Image: "wallarm:main"}}
	got = ExpandWallarmVariants([]string{"nginx", "wallarm"}, single)
	want = []string{"nginx", "wallarm"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ExpandWallarmVariants 1: got %v, want %v", got, want)
	}

	// Nil variants: no-op.
	got = ExpandWallarmVariants([]string{"wallarm", "kong"}, nil)
	want = []string{"wallarm", "kong"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ExpandWallarmVariants nil: got %v, want %v", got, want)
	}
}

func TestCellGatewayBaseAndVariant(t *testing.T) {
	c := Cell{Gateway: "wallarm@branch-main"}
	if c.GatewayBase() != "wallarm" {
		t.Errorf("GatewayBase: got %q, want wallarm", c.GatewayBase())
	}
	if c.GatewayVariant() != "branch-main" {
		t.Errorf("GatewayVariant: got %q, want branch-main", c.GatewayVariant())
	}
	c = Cell{Gateway: "nginx"}
	if c.GatewayBase() != "nginx" || c.GatewayVariant() != "" {
		t.Errorf("plain name: base=%q variant=%q", c.GatewayBase(), c.GatewayVariant())
	}
}

func TestSelectionExpandWithWallarmVariants(t *testing.T) {
	sel := Selection{
		Gateways: []string{"wallarm", "nginx"},
		Policies: []string{"p01-vanilla"},
		Loads:    []string{"p1-baseline"},
		WallarmVariants: []WallarmVariant{
			{Name: "branch-main", Image: "wallarm:branch-main"},
			{Name: "branch-other", Image: "wallarm:branch-other"},
		},
	}
	cells, err := sel.Expand()
	if err != nil {
		t.Fatal(err)
	}
	if len(cells) != 3 {
		t.Fatalf("want 3 cells (2 wallarm variants + 1 nginx), got %d", len(cells))
	}
	if cells[0].Gateway != "wallarm@branch-main" || cells[0].WallarmImage != "wallarm:branch-main" {
		t.Errorf("cell[0] unexpected: %+v", cells[0])
	}
	if cells[1].Gateway != "wallarm@branch-other" || cells[1].WallarmImage != "wallarm:branch-other" {
		t.Errorf("cell[1] unexpected: %+v", cells[1])
	}
	if cells[2].Gateway != "nginx" || cells[2].WallarmImage != "" {
		t.Errorf("cell[2] unexpected: %+v", cells[2])
	}
}

func TestCanonicalReportCellsWithVariants(t *testing.T) {
	variants := []WallarmVariant{
		{Name: "a", Image: "wallarm:a"},
		{Name: "b", Image: "wallarm:b"},
	}
	cells, err := CanonicalReportCellsWithVariants(
		[]string{"wallarm"}, []string{"p1-baseline"}, 1, variants,
	)
	if err != nil {
		t.Fatal(err)
	}
	// 13 policy/scenario pairs (11 HTTP + 2 HTTPS) × 2 variants
	if len(cells) != 26 {
		t.Fatalf("want 26 cells, got %d", len(cells))
	}
	sawA, sawB := false, false
	for _, c := range cells {
		switch c.Gateway {
		case "wallarm@a":
			sawA = true
			if c.WallarmImage != "wallarm:a" {
				t.Errorf("wallarm@a cell has image %q, want wallarm:a", c.WallarmImage)
			}
		case "wallarm@b":
			sawB = true
			if c.WallarmImage != "wallarm:b" {
				t.Errorf("wallarm@b cell has image %q, want wallarm:b", c.WallarmImage)
			}
		default:
			t.Errorf("unexpected gateway %q", c.Gateway)
		}
	}
	if !sawA || !sawB {
		t.Errorf("missing variant: sawA=%v sawB=%v", sawA, sawB)
	}
}

func TestSortStableGatewayVariants(t *testing.T) {
	in := []string{"kong", "wallarm@b", "nginx", "wallarm@a"}
	out := SortStable("gateways", in)
	// Canonical order: nginx, wallarm*, kong. Variants keep input order.
	want := []string{"nginx", "wallarm@b", "wallarm@a", "kong"}
	if !reflect.DeepEqual(out, want) {
		t.Errorf("SortStable gateways: got %v, want %v", out, want)
	}
}
