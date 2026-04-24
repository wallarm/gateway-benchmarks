// Package report renders the canonical HTML benchmark report from
// reports/<run-id>/{cells.jsonl, manifest.json}. It deliberately
// re-implements the projection that scripts/render-html-report.py
// produced during Phase 4–5 so the orchestrator binary stays the
// single source of truth (no Python required on a reviewer's host).
//
// This file holds the static catalog: gateway palette, language /
// version metadata, and the policy / scenario descriptions surfaced
// in each tab. Keep these in lock-step with:
//
//   - docs/POLICIES.md            (canonical policy semantics)
//   - docs/LOAD-PROFILES.md       (load profile shapes)
//   - gateways/<gw>/docker-compose.yaml (image + version pins)
//
// When a gateway image pin is bumped, update GatewayStack here in
// the same commit.
package report

// GatewayColors is the per-gateway brand palette used across every
// chart so the same gateway stays visually identifiable as the user
// jumps between tabs. Mirrors the prototype in
// scripts/render-html-report.py.
var GatewayColors = map[string]string{
	"nginx":   "#009639",
	"envoy":   "#AC6EF5",
	"traefik": "#24A1C1",
	"kong":    "#003459",
	"apisix":  "#E8433E",
	"tyk":     "#1A1A2E",
	"wallarm": "#FF6B35",
	"backend": "#339AF0",
}

// GatewayStack lists the implementation language and the image tag
// at the time of the most recent run. Bump in lock-step with the
// docker-compose.yaml pins.
var GatewayStack = map[string][2]string{
	"nginx":   {"C", "1.27.3-alpine"},
	"envoy":   {"C++", "v1.32.6 distroless"},
	"traefik": {"Go", "v3.3.4"},
	"kong":    {"Lua", "3.9.1 (OpenResty)"},
	"apisix":  {"Lua", "3.15.0-debian"},
	"tyk":     {"Go", "v5.11.1 CE"},
	"wallarm": {"Rust/C", "main (source build)"},
}

// PolicyOrder is the canonical order of the twelve policy tabs.
// Keep in sync with matrix.CanonicalPolicies — this slice exists
// separately so the report package stays free of the matrix import.
var PolicyOrder = []string{
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

// PolicyMeta describes one canonical policy as surfaced in the UI.
//
//	Label   — short label for the tab button
//	Tested  — one-sentence "what is being tested"
//	Profile — traffic profile blurb (e.g. "503 RPS sustained for 60s")
//	Signal  — what a healthy result looks like (informs reviewer
//	          interpretation; stays compact)
type PolicyMeta struct {
	Label   string
	Tested  string
	Profile string
	Signal  string
}

// PolicyDescriptions captures the editorial blurb surfaced in each
// scenario tab. Wording is intentionally compact — every line lands
// inside a UI card, not a wiki page.
var PolicyDescriptions = map[string]PolicyMeta{
	"p01-vanilla": {
		Label:   "p01 · vanilla",
		Tested:  "Pure passthrough with every uniform setting baked in (timeouts, keep-alive, buffers). The reverse proxy applies no policy.",
		Profile: "Closed-loop iterations through /anything/get; no auth, no body rewrites, no rate limiting.",
		Signal:  "Highest RPS column on every gateway, near-zero overhead vs the baseline backend, errors below 0.1%.",
	},
	"p02-jwt": {
		Label:   "p02 · jwt HS256",
		Tested:  "RFC 7519 JWT validation (HS256), signed by the bench key, issuer + exp checked at the gateway.",
		Profile: "Same closed-loop as p01 but every request carries Authorization: Bearer; 50% of probes use rotated tokens.",
		Signal:  "Throughput drop ≤30% vs p01, exactly 0% errors (every signed token is canonical).",
	},
	"p03-jwks-rs256-basic": {
		Label:   "p03 · jwks RS256",
		Tested:  "RS256 JWT verified against an inline JWKS (kid → JWK lookup + PKCS#1-v1.5 signature verify). Public key only.",
		Profile: "10 VUs × 60s; 33% of probes use a token with an unknown kid (must reject with 401).",
		Signal:  "Throughput ≤ p02 (asymmetric verify cost > HMAC), zero unexpected 4xx/5xx, every unknown-kid request rejected.",
	},
	"p04-rl-static": {
		Label:   "p04 · rl-static",
		Tested:  "Service-wide token bucket: 1000 rps, burst 200. The whole API instance shares one counter.",
		Profile: "10 VUs hammer the limited path until the bucket saturates; expected steady-state is 1000 RPS + 429s.",
		Signal:  "policy_4xx_expected (429) carries most non-2xx traffic; policy_4xx_unexpected ≈ 0.",
	},
	"p05-rl-endpoint": {
		Label:   "p05 · rl-endpoint",
		Tested:  "Per-route bucket: only /anything/limited has a 100 rps cap; /anything/free is unrestricted.",
		Profile: "10 VUs split across both paths; the harness verifies the free endpoint never sees a 429.",
		Signal:  "Two-tier shape — /limited tops out at 100 RPS + 429 mass, /free reaches gateway max throughput.",
	},
	"p06-rl-dynamic-low": {
		Label:   "p06 · rl-dyn-low",
		Tested:  "Per-source-IP bucket sized at 10 rps. Traffic synthesises 10 unique X-Real-IP values.",
		Profile: "10 VUs spray those IPs round-robin; each IP saturates its own 10 rps bucket and overflows into 429.",
		Signal:  "Aggregate ≈ 100 RPS (10 IPs × 10 rps), the rest counted as policy_4xx_expected.",
	},
	"p07-rl-dynamic-high": {
		Label:   "p07 · rl-dyn-high",
		Tested:  "Higher-cardinality per-IP bucket: 100 rps each across 50 unique IPs.",
		Profile: "Closed-loop spray across 50 X-Real-IP values; loadgen tries to keep every bucket warm.",
		Signal:  "Aggregate ≈ 5000 RPS at saturation, 429 mass on overflow, no unexpected 5xx.",
	},
	"p08-req-headers": {
		Label:   "p08 · req-headers",
		Tested:  "Request-header rewrite: inject X-Bench-Tagged on every upstream call, drop X-Forwarded-For.",
		Profile: "Closed-loop p01 with the gateway transformer enabled; backend echoes headers so the harness can verify.",
		Signal:  "Throughput within 5–10% of p01; XFF never reaches the backend.",
	},
	"p09-resp-headers": {
		Label:   "p09 · resp-headers",
		Tested:  "Response-header rewrite: inject X-Bench-Pipeline on every reply, suppress the gateway's own Server header.",
		Profile: "Closed-loop p01; the harness asserts both the inject and the strip.",
		Signal:  "Throughput within 5–10% of p01; no Server header leaks through.",
	},
	"p10-req-body": {
		Label:   "p10 · req-body",
		Tested:  "Request body JSON rewrite: inject $.bench.injected, drop $.secret. Content-Length recomputed.",
		Profile: "Closed-loop POST with a 200-byte body; backend echoes the rewritten payload.",
		Signal:  "Backend always sees the injected key and never sees the secret. Throughput typically 30–50% of p01 (body parse cost).",
	},
	"p11-resp-body": {
		Label:   "p11 · resp-body",
		Tested:  "Response body JSON rewrite: inject $.bench.injected, drop $.origin. Content-Length recomputed.",
		Profile: "Closed-loop GET; the gateway buffers the upstream body, mutates it, then forwards.",
		Signal:  "Throughput cost similar to p10; the harness checks both the inject and the strip.",
	},
	"p12-full-pipeline": {
		Label:   "p12 · full-pipe",
		Tested:  "Composite of p02 + p04 + p07 + p08 + p09 + p10 in one request flow. Real-world worst-case shape.",
		Profile: "Closed-loop with valid JWTs; rate-limit fires before JWT validation so flooding gets shed cheaply.",
		Signal:  "policy_4xx_expected (429 from RL) carries the bulk; throughput floor depends on phase ordering, not policy count.",
	},
}

// LoadProfileMeta describes one of the load profile shapes the
// orchestrator supports. Keep in sync with k6/profiles/*.js.
type LoadProfileMeta struct {
	Label   string // short tag for the sub-section header
	Shape   string // executor + numbers (e.g. "constant 10 VUs × 60s")
	Purpose string // why this shape exists
}

// LoadDescriptions surface the executor + numbers next to every
// sub-section so a reviewer doesn't have to dig into k6/profiles.
var LoadDescriptions = map[string]LoadProfileMeta{
	"p1-baseline": {
		Label:   "p1 · baseline",
		Shape:   "constant 10 VUs × 60s (closed-loop)",
		Purpose: "Cheap canonical comparison run; matches api7/apisix-benchmark conventions.",
	},
	"p2-sustained": {
		Label:   "p2 · sustained",
		Shape:   "constant 100 VUs × 5m (closed-loop)",
		Purpose: "Steady-state RSS + warm-cache CPU; what an operator would actually see.",
	},
	"p3-ramp": {
		Label:   "p3 · ramp",
		Shape:   "ramp 10 → 200 VUs over 3m, hold 2m (closed-loop)",
		Purpose: "Probe how the gateway recovers from a load spike.",
	},
	"p4-stress": {
		Label:   "p4 · stress",
		Shape:   "constant 500 VUs × 2m (closed-loop)",
		Purpose: "Push past comfortable load to surface tail-latency / dropped requests.",
	},
	"p1c-paced": {
		Label:   "p1c · paced",
		Shape:   "constant-arrival 500 RPS × 60s",
		Purpose: "Absolute-RPS twin of p1 — measures latency at a fixed offered load.",
	},
	"p2c-paced": {
		Label:   "p2c · paced",
		Shape:   "constant-arrival 2000 RPS × 5m",
		Purpose: "Absolute-RPS twin of p2 — same length, predictable arrival rate.",
	},
	"p3c-paced": {
		Label:   "p3c · paced",
		Shape:   "ramping-arrival 0 → 10000 RPS over 3m",
		Purpose: "Find the throughput knee under controlled arrival ramp.",
	},
	"p4c-paced": {
		Label:   "p4c · paced",
		Shape:   "constant-arrival 20000 RPS × 2m",
		Purpose: "Hard-shed test: oversubscribe arrivals deliberately.",
	},
}

// LoadOrder is the canonical sub-section order inside a tab. Closed-
// loop profiles come first, paced-arrival twins follow.
var LoadOrder = []string{
	"p1-baseline",
	"p2-sustained",
	"p3-ramp",
	"p4-stress",
	"p1c-paced",
	"p2c-paced",
	"p3c-paced",
	"p4c-paced",
}
