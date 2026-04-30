// k6/scenarios/s14-full-pipeline-https.js

// Scenario s14-full-pipeline-https (TASK §7 / docs/POLICIES.md § HTTPS scenarios):
//
//   Drives the `p12-full-pipeline` policy over HTTPS/1.1. Pairs with
//   s13 (`p01-vanilla` over HTTPS) to bracket the TLS-overhead delta:
//   s13 measures TLS cost on top of the simplest downstream path,
//   s14 measures TLS cost on top of the most complex one (JWT + RL +
//   req/resp headers + req/resp body + upstream). The downstream
//   policy plumbing is byte-for-byte identical to s12 — only the URL
//   scheme changes, so any delta (s14 − s12) that isn't (s13 − s01)
//   is an interaction between TLS termination and the composed
//   policy chain (e.g. a gateway that does TLS offload on the same
//   worker thread that runs Lua filters would show a non-linear
//   TLS+pipeline cost here but not in s13).
//
// HTTP path: POST /anything (same echo endpoint s12 uses).
// Body: the canonical p12 payload from `lib/payloads.js` — carries a
//   `secret` field the gateway must drop and a `bench.from_client`
//   marker the gateway must preserve.
// Auth: valid HS256 Bearer via `authHeader()` (lib/jwt.js). A missing
//   or invalid token is out-of-scope here; parity covers the 401 paths.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`.
//
// Expected signal:
//   Same pipeline-integrity signal as s12 — a 200 missing any of
//   `X-Bench-Out`, injected body field, or stripped
//   `Server`/`X-Forwarded-For`/`secret` is a silent correctness
//   regression. The checks flag each axis independently so the report
//   pinpoints which stage regressed.
//
//   - Happy path: 200 with every transform applied (p1-baseline and
//     most of p2-sustained / p3-ramp where 1000 rps is never breached).
//   - 429 is expected signal on p3-ramp / p4-stress once the offered
//     load exceeds the RL bucket; we do NOT assert pipeline integrity
//     on 429s, same as s12.
//   - 5xx counter must stay at 0 on p1/p2/p3; p4 may surface non-zero
//     5xx as the gateway saturates.
//
// DEAD UNTIL PHASE 5: this scenario throws at init if
// BENCH_TARGET_URL_HTTPS is empty or does not start with `https://`.
// See s13-vanilla-https.js for the full rationale. The canonical
// `p12 → s12-full-pipeline-http` mapping in
// `scripts/load-orchestrator.sh` is unchanged; s14 is an orthogonal
// protocol axis, not a replacement of s12.

import { benchTargetUrlHttps } from '../lib/env.js';
import { authHeader } from '../lib/jwt.js';
import { classify } from '../lib/metrics.js';
import { options as resolvedOptions } from '../lib/options.js';
import { p11RequestBody } from '../lib/payloads.js';

import { check } from 'k6';
import http from 'k6/http';

// Scenario-level override of the p95 latency threshold to absorb the
// TLS termination cost that s12 never sees. Rationale:
//
//   - s12 inherits `http_req_duration: ['p(95)<200ms']` from
//     `k6/profiles/p1-baseline.js` (other profiles use wider budgets).
//     That 200 ms floor is sized for plain HTTP over the in-bench
//     network, where the gateway's per-request work is a few dozen
//     microseconds and the rest is TCP + keep-alive bookkeeping.
//   - TLS 1.2/1.3 termination adds (a) a one-time handshake cost per
//     VU (order of single-digit ms on localhost docker-desktop, tens
//     on a real AWS c6i box), amortised over a 60 s run with
//     keep-alive; (b) a constant per-request symmetric-cipher cost
//     (typically <1 ms for AES-128-GCM at this payload size). On a
//     p1-baseline 60 s × 10 VU run, the amortised lift to p95 is a
//     few ms — nowhere near +20%.
//   - The +20% widening (200 → 240 ms) is deliberately generous: it
//     absorbs the worst-case scenario where a gateway does synchronous
//     TLS record-sealing on the same event-loop turn as the Lua
//     filters (an anti-pattern we want to surface in the report, not
//     fail the run on). A real TLS-termination regression — e.g. a
//     gateway falling back to software AES-GCM when hardware AES-NI
//     should be engaged — would blow well past 240 ms, and that's
//     exactly the regression we want the threshold to catch.
//
// Interaction with non-p1 load profiles: this inline threshold
// REPLACES the profile's `http_req_duration` in k6 semantics (thresholds
// are keyed by metric name, not merged). Under p2-sustained (profile
// threshold `p(95)<300 ms`) or p3-ramp (`p(95)<500 ms`), s14's 240 ms
// is tighter than the profile default, which is fine: a 240 ms p95 on
// TLS full-pipeline at 100 VUs or during a 10→500 ramp is still well
// within the "functionally healthy" envelope — anything above that
// deserves attention regardless of load profile. p4-stress ships
// without an http_req_duration threshold in its profile, so the
// scenario-level override adds one (240 ms is loose enough to not
// false-trip on stress saturation, where 5xx / client-timeouts are
// the dominant signal anyway). Phase 5 will revisit per-profile
// widening if observation warrants it.
// Scenario-level threshold override removed — see
// k6/profiles/p1-baseline.js for the rationale (we measure latency
// rather than fail on it; the report renders absolute p95 columns).
export const options = resolvedOptions;

// Init-phase guards (shape identical to s13): hard fail on an empty
// BENCH_TARGET_URL_HTTPS (Phase 5 not wired) and hard fail on a
// non-`https://` URL (operator typo defending against an ugly TLS-
// ClientHello-into-HTTP-parser reset avalanche).
const BASE_URL = benchTargetUrlHttps();
if (!BASE_URL) {
    throw new Error(
        '[k6/scenarios/s14] BENCH_TARGET_URL_HTTPS is not set. This ' +
        'scenario measures TLS overhead on the full policy pipeline ' +
        'and requires Phase 5 TLS plumbing (cert chain under ' +
        'gateways/_reference/tls/, `listen 443 ssl;` on each gateway ' +
        'config, :8443 exposed in docker-compose.yaml). Until Phase 5 ' +
        'lands, s14 is dead code — the orchestrator does not invoke ' +
        'it; the canonical p12-full-pipeline → s12-full-pipeline-http ' +
        'mapping stays default.',
    );
}
if (!BASE_URL.startsWith('https://')) {
    throw new Error(
        `[k6/scenarios/s14] BENCH_TARGET_URL_HTTPS='${BASE_URL}' does ` +
        'not start with "https://". This scenario measures TLS-overhead ' +
        'on the full pipeline; pointing it at a plain-HTTP listener ' +
        'would fire TLS ClientHello bytes at an HTTP parser and produce ' +
        'a connection-reset avalanche. Set BENCH_TARGET_URL_HTTPS to an ' +
        'https:// URL (Phase 5 default: https://gateway:9443 inside ' +
        'bench-net, https://bench.local:8443 from the host).',
    );
}

// `authHeader()` resolves BENCH_JWT_VALID at init (k6 init phase), so
// a missing or empty token fails the run before any traffic leaves
// the box — same contract s12 relies on.
const AUTH = authHeader();
const BODY = JSON.stringify(p11RequestBody);

export default function () {
    const res = http.post(`${BASE_URL}/anything`, BODY, {
        headers: {
            ...AUTH,
            'Content-Type': 'application/json',
            // Decoy header the req-headers stage MUST strip before
            // the request reaches the backend — identical to s12.
            // The pipeline-integrity check below reads it back out of
            // the echoed body to confirm the drop.
            'X-Forwarded-For': '198.51.100.7',
            // `Host` + `User-Agent` overrides match s13 — see s13's
            // header block for the SNI-routing / log-scraping rationale.
            'Host':            'bench.local',
            'User-Agent':      'gateway-benchmarks/k6-s14',
        },
        tags: { url: '/anything' },
    });

    classify(res);

    // Checks are byte-for-byte identical to s12 — p12's compositional
    // plumbing is the signal; TLS is an orthogonal overhead axis and
    // the TLS handshake itself is captured in the `http_req_tls_handshaking`
    // trend metric (summary export), not as a per-iteration check.
    check(res, {
        'status is 200 or 429': (r) => r.status === 200 || r.status === 429,
        'when 200: response has X-Bench-Out header': (r) => {
            if (r.status === 429) return true;
            return r.headers['X-Bench-Out'] === '1';
        },
        'when 200: response does not have Server header': (r) => {
            if (r.status === 429) return true;
            return r.headers['Server'] === undefined;
        },
        'when 200: response body has bench.injected=true': (r) => {
            if (r.status === 429) return true;
            try {
                const body = JSON.parse(r.body);
                return body.bench && body.bench.injected === true;
            } catch {
                return false;
            }
        },
        'when 200: response body does not have origin': (r) => {
            if (r.status === 429) return true;
            try {
                const body = JSON.parse(r.body);
                return body.origin === undefined;
            } catch {
                return false;
            }
        },
        'when 200: backend saw X-Bench-In, did not see X-Forwarded-For, did not see secret': (r) => {
            if (r.status === 429) return true;
            try {
                const body = JSON.parse(r.body);
                const sawBenchIn = body.headers && body.headers['X-Bench-In'] === '1';
                const missedXff = body.headers && body.headers['X-Forwarded-For'] === undefined;
                const missedSecret = body.json && body.json.secret === undefined;
                const sawInjected = body.json && body.json.bench && body.json.bench.injected === true;
                return sawBenchIn && missedXff && missedSecret && sawInjected;
            } catch {
                return false;
            }
        },
    });
}
