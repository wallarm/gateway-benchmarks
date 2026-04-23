// k6/scenarios/s13-vanilla-https.js

// Scenario s13-vanilla-https (TASK §7 / docs/POLICIES.md § HTTPS scenarios):
//
//   Drives the `p01-vanilla` policy over HTTPS/1.1. Pairs with s14
//   (`p12-full-pipeline` over HTTPS) to bracket the TLS-overhead
//   delta: s13 measures TLS cost on top of the *simplest* downstream
//   path (pure proxy, no policies), s14 measures TLS cost on top of
//   the *most complex* downstream path (every policy stage composed).
//   The delta between (s13 − s01) and (s14 − s12) attributes the cost
//   to TLS alone, since the TLS handshake itself is uniform across
//   policy profiles — the gateway always terminates the same bytes.
//
// HTTP path: GET /anything (go-httpbin echo endpoint, same as s01).
// Body: none.
// Auth: none.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`.
//
// Expected signal:
//   - 100% of responses should be 2xx on p1/p2/p3 (the gateway has
//     nothing to reject and the backend always answers 200); p4 may
//     surface non-zero 5xx as the gateway saturates, same as s01.
//   - First-request-per-VU TLS handshake must actually happen — the
//     check below asserts `timings.tls_handshaking > 0` on `__ITER === 0`.
//     Subsequent iterations reuse the TLS session on the same TCP
//     connection and correctly report `tls_handshaking === 0`; the
//     check short-circuits there.
//   - The built-in `http_req_tls_handshaking` trend metric in the
//     summary export is what the report generator (Phase 7) plots
//     per-gateway alongside `http_req_duration` to split the p95 cost
//     into (TLS handshake, TTFB, transfer).
//
// DEAD UNTIL PHASE 5: this scenario throws at init if
// BENCH_TARGET_URL_HTTPS is empty or does not start with `https://`.
// Phase 5 lands the TLS plumbing (cert chain under
// `gateways/_reference/tls/`, `listen 443 ssl;` on each gateway
// config, `:8443` host-port binding in compose); until that ships,
// the orchestrator never sets BENCH_TARGET_URL_HTTPS and s13 stays
// dormant. The canonical `p01 → s01-vanilla-http` mapping in
// `scripts/load-orchestrator.sh` is unchanged — s13 is an
// *orthogonal* protocol axis, not a replacement of s01.

import { benchTargetUrlHttps } from '../lib/env.js';
import { classify } from '../lib/metrics.js';
import { options as resolvedOptions } from '../lib/options.js';

import { check } from 'k6';
import http from 'k6/http';

export const options = resolvedOptions;

// Two init-phase guards, both firing before any traffic leaves the
// box so a silent misconfiguration cannot feed bogus numbers into the
// summary export:
//
//   1. BENCH_TARGET_URL_HTTPS is empty → Phase 5 TLS plumbing hasn't
//      landed / wasn't selected. Fail with a message that points at
//      the Phase 5 checklist so the operator knows exactly which
//      switch is missing.
//
//   2. BENCH_TARGET_URL_HTTPS doesn't start with `https://` → someone
//      set it to `http://localhost:9080` (or similar) by mistake.
//      Without this guard, k6 would fire TLS ClientHello bytes at an
//      HTTP listener and produce a `connection reset by peer`
//      avalanche — noisy, misleading, and hard to attribute. Catching
//      the scheme mismatch here turns it into a single clean init
//      error instead of an 60-second run of mystery resets.
const BASE_URL = benchTargetUrlHttps();
if (!BASE_URL) {
    throw new Error(
        '[k6/scenarios/s13] BENCH_TARGET_URL_HTTPS is not set. This ' +
        'scenario measures TLS overhead and requires Phase 5 TLS ' +
        'plumbing (cert chain under gateways/_reference/tls/, ' +
        '`listen 443 ssl;` on each gateway config, :8443 exposed in ' +
        "docker-compose.yaml). Until Phase 5 lands, s13 is dead code — " +
        'the orchestrator does not invoke it; the canonical ' +
        'p01-vanilla → s01-vanilla-http mapping stays default.',
    );
}
if (!BASE_URL.startsWith('https://')) {
    throw new Error(
        `[k6/scenarios/s13] BENCH_TARGET_URL_HTTPS='${BASE_URL}' does ` +
        'not start with "https://". This scenario measures TLS-overhead ' +
        'delta; pointing it at a plain-HTTP listener would fire TLS ' +
        'ClientHello bytes at an HTTP parser and produce a connection-' +
        'reset avalanche. Set BENCH_TARGET_URL_HTTPS to an https:// URL ' +
        '(Phase 5 default: https://gateway:9443 inside bench-net, ' +
        'https://bench.local:8443 from the host).',
    );
}

export default function () {
    const res = http.get(`${BASE_URL}/anything`, {
        // `Host: bench.local` matches the canonical cert CN Phase 5
        // ships under `gateways/_reference/tls/`. Some gateways (nginx
        // with `server_name bench.local;` on the 443 listener, traefik
        // with SNI-based routers) reject requests whose Host header
        // doesn't match a configured server block; setting it
        // explicitly keeps s13 portable across all seven gateways.
        //
        // `User-Agent` tags s13 traffic so post-mortem access-log
        // scraping (when an operator toggles it on for a debugging
        // session) can split s13 from s01 without touching k6 tags.
        headers: {
            'Host':       'bench.local',
            'User-Agent': 'gateway-benchmarks/k6-s13',
        },
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200':                     (r) => r.status === 200,
        'response_body has json.method=GET': (r) => {
            try { return JSON.parse(r.body).method === 'GET'; }
            catch { return false; }
        },
        // TLS handshake must actually occur on the first iteration of
        // each VU. k6 reuses the TLS session for subsequent requests
        // on the same connection (every profile ships
        // `noConnectionReuse: false`), so later iterations report
        // `tls_handshaking === 0` — which is correct, not a regression,
        // and the check short-circuits with `true` on !== 0. A VU that
        // never observes a handshake at all means the gateway fell
        // back to plain HTTP (or k6 resolved a cached connection from
        // a prior scenario, which this framework does not run).
        'tls_handshaking observed on first iter': (r) => {
            if (__ITER !== 0) return true;
            return r.timings.tls_handshaking > 0;
        },
    });
}
