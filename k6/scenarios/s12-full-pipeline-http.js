// k6/scenarios/s12-full-pipeline-http.js
//
// Scenario s12-full-pipeline-http (TASK §4 / docs/POLICIES.md § p12-full-pipeline):
//
//   Drives the `p12-full-pipeline` policy — the composition of every
//   single-stage axis from p02..p11 in one request/response flow:
//
//     JWT (HS256 valid)
//       ▶ RL (1000/s static bucket)
//       ▶ req-headers: add X-Bench-In: 1, drop X-Forwarded-For
//       ▶ req-body:    add $.bench.injected=true, drop $.secret
//       ▶ upstream (go-httpbin /anything echoes the transformed request)
//       ▶ resp-body:   add $.bench.injected=true, drop $.origin
//       ▶ resp-headers: add X-Bench-Out: 1, drop Server
//
// HTTP path: POST /anything (go-httpbin echoes the transformed request,
// so we can introspect what reached the backend in the response body).
// Body: the canonical p12 payload from lib/payloads.js — carries a
// `secret` field the gateway must drop and a `bench.from_client` marker
// the gateway must preserve.
// Auth: valid HS256 Bearer via authHeader() (lib/jwt.js). A missing or
// invalid token is out-of-scope here; parity covers the 401 paths.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`.
//
// Expected signal:
//   Unlike single-stage scenarios, s12 is the composition check — a 200
//   that is MISSING any of `X-Bench-Out`, injected body field, stripped
//   `Server` / `X-Forwarded-For` / `secret` represents a **silent
//   correctness regression** (the gateway answered 200 but dropped a
//   stage). The checks flag each axis independently so the report
//   pinpoints which stage regressed.
//
//   - Happy path: 200 with every transform applied (p1 baseline and
//     most of p2/p3 sustained, where 1000 rps is never breached).
//   - 429 is expected signal once p3-ramp / p4-stress push the
//     offered load past the RL bucket — it means the RL stage
//     short-circuited BEFORE the rest of the pipeline ran. We do NOT
//     assert pipeline-integrity on 429 responses; classify() captures
//     the status separately via policy_4xx_expected.
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates.

import http from 'k6/http';
import { check } from 'k6';

import { options as resolvedOptions } from '../lib/options.js';
import { targetUrl } from '../lib/env.js';
import { classify } from '../lib/metrics.js';
import { authHeader } from '../lib/jwt.js';
import { p11RequestBody } from '../lib/payloads.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration. authHeader()
// also runs here so a missing BENCH_JWT_VALID fails the run before any
// traffic leaves the box.
const BASE_URL = targetUrl();
const AUTH = authHeader();
const BODY = JSON.stringify(p11RequestBody);

export default function () {
    const res = http.post(`${BASE_URL}/anything`, BODY, {
        headers: {
            ...AUTH,
            'Content-Type': 'application/json',
            // Decoy header the req-headers stage MUST strip before the
            // request reaches the backend. The pipeline-integrity check
            // below reads it back out of the echoed body to confirm it
            // was dropped (not merely invisible to the client).
            'X-Forwarded-For': '198.51.100.7',
        },
        tags: { url: '/anything' },
    });

    classify(res);

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
