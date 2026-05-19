// Package matrix expands the user's CLI selection (gateways,
// policies, scenarios, loads) into the cartesian product of cells
// the orchestrator must execute. The mapping mirrors what
// scripts/load-orchestrator.sh § "Resolve policies, scenarios,
// loads" does — keep them in sync.
package matrix

import (
	"fmt"
	"sort"
	"strings"
)

// CanonicalPolicies is the canonical policy ordering used in the
// 12-row HTML report. Keep in sync with:
//   - scripts/load-orchestrator.sh § CANONICAL_POLICIES
//   - docs/POLICIES.md
//   - k6/scenarios/sNN-*.js mapping
var CanonicalPolicies = []string{
	"p01-vanilla",
	"p02-jwt",
	"p03-jwks-rs256-basic",
	"p04-rl-static",
	"p05-rl-endpoint",
	"p06-rl-dynamic-low",
	"p07-rl-dynamic-high",
	"p08-req-headers",
	"p09-resp-headers",
	"p10-req-body",
	"p11-resp-body",
	"p12-full-pipeline",
}

// CanonicalRankingPolicies excludes the supplemental p03 capability
// profile. The published ranking matrix is:
//   - 11 HTTP ranking profiles (p01,p02,p04..p12)
//   - 2 HTTPS scenarios tied to p01 and p12
//
// p03 still exists for parity/capability checks, but does not consume
// load budget in the canonical report.
var CanonicalRankingPolicies = []string{
	"p01-vanilla",
	"p02-jwt",
	"p04-rl-static",
	"p05-rl-endpoint",
	"p06-rl-dynamic-low",
	"p07-rl-dynamic-high",
	"p08-req-headers",
	"p09-resp-headers",
	"p10-req-body",
	"p11-resp-body",
	"p12-full-pipeline",
}

// CanonicalGateways is the canonical column ordering. Tests pin the
// list explicitly; CLI flags can override.
var CanonicalGateways = []string{
	"nginx",
	"wallarm",
	"envoy",
	"traefik",
	"kong",
	"apisix",
	"tyk",
}

// CanonicalLoads is the closed-loop default order. Paced-arrivals
// twins (p1c-paced ... p4c-paced) are opt-in and not part of the
// default canonical sweep. Keep in sync with:
//   - scripts/load-gateway.sh § "Accepted load profiles"
//   - k6/profiles/p*-*.js
//   - docs/LOAD-PROFILES.md
var CanonicalLoads = []string{
	"p1-baseline",
	"p2-sustained",
	"p3-ramp",
	"p4-stress",
}

// AllowedLoads is the union of closed-loop and paced-arrivals
// profiles accepted by load-gateway.sh.
var AllowedLoads = map[string]struct{}{
	"p1-baseline": {}, "p2-sustained": {}, "p3-ramp": {}, "p4-stress": {},
	"p1c-paced": {}, "p2c-paced": {}, "p3c-paced": {}, "p4c-paced": {},
}

// HTTPSScenarios are tied to specific policies — only p01 and p12
// have :9443 listeners on every gateway (TLS scaffolding landed in
// Phase 5, see docs/POLICIES.md § HTTPS scenarios).
var HTTPSScenarios = map[string]string{
	"p01-vanilla":       "s13-vanilla-https",
	"p12-full-pipeline": "s14-full-pipeline-https",
}

// Cell is a single (gateway, policy, scenario, load) coordinate.
// Repetition is the 1-indexed pass within a multi-rep run.
//
// Gateway may carry a "@<variant>" suffix when the operator passes
// WALLARM_IMAGE as a comma-separated list (one wallarm column per
// image — see ExpandWallarmVariants). The base name (before "@") is
// the directory under gateways/ that owns docker-compose.yaml /
// setup.sh; the suffix only flavours the column label and the per-
// cell raw/ output directory.
type Cell struct {
	Gateway    string `json:"gateway"`
	Policy     string `json:"policy"`
	Scenario   string `json:"scenario"`
	Load       string `json:"load"`
	Repetition int    `json:"repetition"`

	// WallarmImage is the image to pull for this cell when Gateway
	// names a wallarm variant. Empty for non-wallarm cells and for
	// single-variant runs (where WALLARM_IMAGE remains a scalar env
	// var honoured by gateways/wallarm/docker-compose.yaml directly).
	WallarmImage string `json:"wallarm_image,omitempty"`
}

// ID returns "<gateway>/<policy>/<load>/<scenario>[#repN]" — used
// for log lines, manifest.SelectedRows and checkpoint keys.
func (c Cell) ID() string {
	id := fmt.Sprintf("%s/%s/%s/%s", c.Gateway, c.Policy, c.Load, c.Scenario)
	if c.Repetition > 1 {
		id += fmt.Sprintf("#rep%d", c.Repetition)
	}
	return id
}

// GatewayBase returns the gateway name without any "@<variant>"
// suffix — i.e. the directory under gateways/ that owns the compose
// file and policy subdirs. For non-suffixed names it is identical to
// Cell.Gateway.
func (c Cell) GatewayBase() string {
	return GatewayBase(c.Gateway)
}

// GatewayVariant returns the "@<variant>" suffix part (without the
// "@") or "" when the gateway name has no variant suffix.
func (c Cell) GatewayVariant() string {
	return GatewayVariant(c.Gateway)
}

// GatewayBase returns the gateway name without any "@<variant>"
// suffix. Free function so callers that have a plain string (e.g.
// the aggregator reading directory names off disk) can reuse it.
func GatewayBase(name string) string {
	if i := strings.IndexByte(name, '@'); i >= 0 {
		return name[:i]
	}
	return name
}

// GatewayVariant returns the variant suffix or "" when none is set.
func GatewayVariant(name string) string {
	if i := strings.IndexByte(name, '@'); i >= 0 {
		return name[i+1:]
	}
	return ""
}

// OutputDir mirrors scripts/load-gateway.sh's per-cell directory
// layout: reports/<RUN_ID>/raw/<gateway>/<policy>__<load>__<scenario>
// with a #repN suffix for repetitions > 1.
func (c Cell) OutputDir(runID string) string {
	dir := fmt.Sprintf("reports/%s/raw/%s/%s__%s__%s",
		runID, c.Gateway, c.Policy, c.Load, c.Scenario)
	if c.Repetition > 1 {
		dir += fmt.Sprintf("__rep%d", c.Repetition)
	}
	return dir
}

// Selection holds the resolved CLI input.
type Selection struct {
	Gateways    []string
	Policies    []string
	Scenarios   []string // one-per-policy, in order; auto-derived if empty
	Loads       []string
	Repetitions int

	// WallarmVariants, when set with 2+ entries, expands every
	// "wallarm" entry in Gateways into one "wallarm@<variant>" entry
	// per variant. With 0 or 1 entries the wallarm column stays a
	// single "wallarm" — matching legacy single-image behaviour.
	WallarmVariants []WallarmVariant
}

// WallarmVariant pairs the human-readable label that becomes the
// gateway column suffix ("wallarm@<name>") with the docker image
// reference that should be set as WALLARM_IMAGE for cells in that
// column.
type WallarmVariant struct {
	Name  string
	Image string
}

// ParseWallarmImageEnv parses a WALLARM_IMAGE env value into a list
// of variants. A scalar (no comma) returns a single variant whose
// Name is derived from the image tag and Image is the input verbatim.
// An empty / whitespace-only input returns nil.
//
// The variant name is the last colon-separated segment of the image
// reference, sanitised to docker-name safe characters. Duplicate
// names get a "-N" disambiguator. Examples:
//
//	"wallarm:branch-main"
//	   → [{Name: "branch-main", Image: "wallarm:branch-main"}]
//
//	"wallarm:branch-main,wallarm:branch-other"
//	   → [{Name: "branch-main", Image: "wallarm:branch-main"},
//	      {Name: "branch-other", Image: "wallarm:branch-other"}]
func ParseWallarmImageEnv(env string) []WallarmVariant {
	parts := ParseCSV(env)
	if len(parts) == 0 {
		return nil
	}
	out := make([]WallarmVariant, 0, len(parts))
	seen := make(map[string]int, len(parts))
	for _, image := range parts {
		name := variantNameFromImage(image)
		if dup, ok := seen[name]; ok {
			seen[name] = dup + 1
			name = fmt.Sprintf("%s-%d", name, dup+1)
		} else {
			seen[name] = 1
		}
		out = append(out, WallarmVariant{Name: name, Image: image})
	}
	return out
}

// variantNameFromImage extracts a docker-safe label from an image
// reference. Prefers the tag after the last ':'; falls back to the
// last path segment when the reference has no tag (e.g. bare digest).
func variantNameFromImage(image string) string {
	candidate := image
	if i := strings.LastIndexByte(candidate, '@'); i >= 0 {
		// digest form: drop the digest, keep the tag if any
		candidate = candidate[:i]
	}
	if i := strings.LastIndexByte(candidate, ':'); i >= 0 {
		candidate = candidate[i+1:]
	} else if i := strings.LastIndexByte(candidate, '/'); i >= 0 {
		candidate = candidate[i+1:]
	}
	candidate = sanitiseVariantName(candidate)
	if candidate == "" {
		return "variant"
	}
	return candidate
}

func sanitiseVariantName(s string) string {
	var b strings.Builder
	lastDash := false
	for _, r := range strings.ToLower(s) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.'
		if ok {
			b.WriteRune(r)
			lastDash = false
			continue
		}
		if !lastDash {
			b.WriteByte('-')
			lastDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}

// ExpandWallarmVariants takes a gateway list and, when 2+ variants
// are supplied, replaces each "wallarm" entry with one
// "wallarm@<variant>" entry per variant. 0 or 1 variants is a no-op
// — single-image runs keep the legacy "wallarm" column name.
func ExpandWallarmVariants(gateways []string, variants []WallarmVariant) []string {
	if len(variants) < 2 {
		return append([]string(nil), gateways...)
	}
	out := make([]string, 0, len(gateways)+len(variants)-1)
	for _, gw := range gateways {
		if GatewayBase(gw) != "wallarm" || GatewayVariant(gw) != "" {
			out = append(out, gw)
			continue
		}
		for _, v := range variants {
			out = append(out, "wallarm@"+v.Name)
		}
	}
	return out
}

// WallarmImageFor returns the image associated with a gateway name
// (e.g. "wallarm@branch-main" → "wallarm:branch-main"). Returns ""
// when the gateway is not a wallarm variant or no matching variant
// exists in the list.
func WallarmImageFor(gateway string, variants []WallarmVariant) string {
	if GatewayBase(gateway) != "wallarm" {
		return ""
	}
	variant := GatewayVariant(gateway)
	if variant == "" {
		// Scalar wallarm column — only meaningful when a single variant
		// was supplied. Return its image so the runner can still inject
		// WALLARM_IMAGE per cell rather than relying on the env leak.
		if len(variants) == 1 {
			return variants[0].Image
		}
		return ""
	}
	for _, v := range variants {
		if v.Name == variant {
			return v.Image
		}
	}
	return ""
}

// Expand returns every cell implied by the selection, in stable
// gateway-major order (matching how the canonical report is rendered).
func (s Selection) Expand() ([]Cell, error) {
	if len(s.Gateways) == 0 {
		return nil, fmt.Errorf("matrix: at least one --gateway is required")
	}
	if len(s.Policies) == 0 {
		return nil, fmt.Errorf("matrix: at least one --policy is required")
	}
	if len(s.Loads) == 0 {
		return nil, fmt.Errorf("matrix: at least one --load is required")
	}
	if s.Repetitions < 1 {
		s.Repetitions = 1
	}

	scenarios := s.Scenarios
	if len(scenarios) == 0 {
		scenarios = make([]string, len(s.Policies))
		for i, p := range s.Policies {
			scenarios[i] = ScenarioFor(p)
		}
	}
	if len(scenarios) != len(s.Policies) {
		return nil, fmt.Errorf("matrix: scenario count (%d) != policy count (%d)",
			len(scenarios), len(s.Policies))
	}

	for _, l := range s.Loads {
		if _, ok := AllowedLoads[l]; !ok {
			return nil, fmt.Errorf("matrix: unknown load profile %q", l)
		}
	}

	gateways := ExpandWallarmVariants(s.Gateways, s.WallarmVariants)
	var cells []Cell
	for _, gw := range gateways {
		image := WallarmImageFor(gw, s.WallarmVariants)
		for i, policy := range s.Policies {
			for _, load := range s.Loads {
				for rep := 1; rep <= s.Repetitions; rep++ {
					cells = append(cells, Cell{
						Gateway:      gw,
						Policy:       policy,
						Scenario:     scenarios[i],
						Load:         load,
						Repetition:   rep,
						WallarmImage: image,
					})
				}
			}
		}
	}
	return cells, nil
}

// CanonicalReportCells expands the published report matrix:
// (11 ranking HTTP profiles + 2 HTTPS scenarios) x loads x gateways x reps.
func CanonicalReportCells(gateways, loads []string, repetitions int) ([]Cell, error) {
	return CanonicalReportCellsWithVariants(gateways, loads, repetitions, nil)
}

// CanonicalReportCellsWithVariants is the variant-aware version of
// CanonicalReportCells. When 2+ wallarm variants are passed, each
// "wallarm" entry expands into one "wallarm@<variant>" column with
// the corresponding image stamped onto every emitted cell.
func CanonicalReportCellsWithVariants(gateways, loads []string, repetitions int, variants []WallarmVariant) ([]Cell, error) {
	if len(gateways) == 0 {
		return nil, fmt.Errorf("matrix: at least one --gateway is required")
	}
	if len(loads) == 0 {
		return nil, fmt.Errorf("matrix: at least one --load is required")
	}
	if repetitions < 1 {
		repetitions = 1
	}
	for _, l := range loads {
		if _, ok := AllowedLoads[l]; !ok {
			return nil, fmt.Errorf("matrix: unknown load profile %q", l)
		}
	}

	type policyScenario struct {
		policy   string
		scenario string
	}
	pairs := make([]policyScenario, 0, len(CanonicalRankingPolicies)+len(HTTPSScenarios))
	for _, policy := range CanonicalRankingPolicies {
		pairs = append(pairs, policyScenario{policy: policy, scenario: ScenarioFor(policy)})
	}
	pairs = append(pairs,
		policyScenario{policy: "p01-vanilla", scenario: HTTPSScenarios["p01-vanilla"]},
		policyScenario{policy: "p12-full-pipeline", scenario: HTTPSScenarios["p12-full-pipeline"]},
	)

	expanded := ExpandWallarmVariants(gateways, variants)
	var cells []Cell
	for _, gw := range expanded {
		image := WallarmImageFor(gw, variants)
		for _, pair := range pairs {
			for _, load := range loads {
				for rep := 1; rep <= repetitions; rep++ {
					cells = append(cells, Cell{
						Gateway:      gw,
						Policy:       pair.policy,
						Scenario:     pair.scenario,
						Load:         load,
						Repetition:   rep,
						WallarmImage: image,
					})
				}
			}
		}
	}
	return cells, nil
}

// ScenarioFor returns the canonical sNN-*-http scenario for a given
// pNN policy slug. Mirrors load-orchestrator.sh's auto-mapping.
func ScenarioFor(policy string) string {
	if !strings.HasPrefix(policy, "p") {
		return policy
	}
	return "s" + policy[1:] + "-http"
}

// ParseCSV splits a comma-separated CLI value into a deduplicated,
// trimmed slice. Empty / all-empty input returns nil (not an empty
// slice) so callers can branch on `len() == 0` or compare against
// `nil` interchangeably.
func ParseCSV(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	seen := make(map[string]struct{}, len(parts))
	var out []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if _, ok := seen[p]; ok {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	return out
}

// ResolveAlias expands well-known shortcuts into the canonical lists:
//   - "all" → CanonicalGateways / CanonicalPolicies / CanonicalLoads
//   - "core" → same as "all" for policies (kept for forward-compat)
//   - "http" → closed-loop loads only (p1..p4)
//   - "paced" → paced-arrivals loads only (p1c..p4c)
func ResolveAlias(kind, value string) []string {
	value = strings.TrimSpace(strings.ToLower(value))
	switch kind {
	case "gateways":
		if value == "all" {
			return append([]string(nil), CanonicalGateways...)
		}
	case "policies":
		if value == "all" || value == "core" {
			return append([]string(nil), CanonicalPolicies...)
		}
	case "loads":
		switch value {
		case "all":
			out := append([]string(nil), CanonicalLoads...)
			out = append(out, "p1c-paced", "p2c-paced", "p3c-paced", "p4c-paced")
			return out
		case "http", "closed-loop":
			return append([]string(nil), CanonicalLoads...)
		case "paced":
			return []string{"p1c-paced", "p2c-paced", "p3c-paced", "p4c-paced"}
		}
	}
	return nil
}

// SortStable sorts a slice in canonical order (CanonicalPolicies for
// "policies", CanonicalGateways for "gateways", CanonicalLoads for
// "loads"). Unknown items go to the end alphabetically.
//
// For "gateways", a "wallarm@<variant>" entry ranks at the same
// position as plain "wallarm"; ties between variants are broken by
// the variant suffix in input order (stable).
func SortStable(kind string, items []string) []string {
	var rank map[string]int
	switch kind {
	case "policies":
		rank = indexed(CanonicalPolicies)
	case "gateways":
		rank = indexed(CanonicalGateways)
	case "loads":
		rank = indexed(CanonicalLoads)
	default:
		out := append([]string(nil), items...)
		sort.Strings(out)
		return out
	}
	out := append([]string(nil), items...)
	keyFor := func(s string) string {
		if kind == "gateways" {
			return GatewayBase(s)
		}
		return s
	}
	sort.SliceStable(out, func(i, j int) bool {
		ki, kj := keyFor(out[i]), keyFor(out[j])
		ri, oi := rank[ki]
		rj, oj := rank[kj]
		switch {
		case oi && oj:
			if ri != rj {
				return ri < rj
			}
			// same base rank — preserve input order for variants.
			return false
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

func indexed(items []string) map[string]int {
	m := make(map[string]int, len(items))
	for i, it := range items {
		m[it] = i
	}
	return m
}
