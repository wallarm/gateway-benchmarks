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
type Cell struct {
	Gateway    string `json:"gateway"`
	Policy     string `json:"policy"`
	Scenario   string `json:"scenario"`
	Load       string `json:"load"`
	Repetition int    `json:"repetition"`
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

	var cells []Cell
	for _, gw := range s.Gateways {
		for i, policy := range s.Policies {
			for _, load := range s.Loads {
				for rep := 1; rep <= s.Repetitions; rep++ {
					cells = append(cells, Cell{
						Gateway:    gw,
						Policy:     policy,
						Scenario:   scenarios[i],
						Load:       load,
						Repetition: rep,
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

func indexed(items []string) map[string]int {
	m := make(map[string]int, len(items))
	for i, it := range items {
		m[it] = i
	}
	return m
}
