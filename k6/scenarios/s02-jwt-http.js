// k6/scenarios/s02-jwt-http.js
//
// Scenario s02-jwt-http (TASK §4 / docs/POLICIES.md § p02):
//
//   Drives the `p02-jwt` policy — HS256 JWT validation against a
//   shared secret (`bench-jwt-hs256-secret-2026`). Measures the cost
//   of the JWT validation hop over and above the vanilla baseline:
//   parse the Authorization header, base64url-decode the compact JWS,
//   HMAC-SHA256 the signing input, constant-time compare the
//   signature, and check `exp`.
//
// HTTP path: GET /anything (same echo endpoint s01 uses).
// Body: none.
// Auth: `Authorization: Bearer <valid HS256 token>`. The token is
// minted once on the host by `scripts/gen-jwt.sh valid` before k6 is
// invoked and passed in via BENCH_JWT_VALID; `lib/jwt.js` resolves it
// during the k6 init phase, so token minting is explicitly not in the
// hot path — every iteration re-uses the same pre-minted bearer.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; nothing extra
// needs to be set here.
//
// This scenario always sends a valid HS256 token — the load phase
// measures the happy path (valid → 200); rejection paths (401 on
// missing / garbage / expired / wrong-secret tokens) are covered by
// parity attestation (fixtures/p02-jwt.jsonl), not here.
//
// Expected signal:
//   - 100% of responses should be 2xx (the token is always valid so
//     the gateway has nothing to reject and the backend's /anything
//     always answers 200).
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (same as s01).
//   - Tail-latency interest: p95 / p99 / p99.9 (the report generator
//     plots these per-gateway side by side).

import http from 'k6/http';
import { check } from 'k6';

import { targetUrl } from '../lib/env.js';
import { authHeader } from '../lib/jwt.js';
import { classify } from '../lib/metrics.js';
import { options as resolvedOptions } from '../lib/options.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration — saves a
// trivial amount of work per request and matches how every other
// scenario will treat its base URL.
const BASE_URL = targetUrl();

// Pre-minted valid HS256 Bearer token, also resolved once at init
// (see `lib/jwt.js`). A missing / empty BENCH_JWT_VALID throws a
// descriptive error before any traffic is generated, so a silent
// misconfiguration can never feed bogus 401s into the summary.
const AUTH_HEADERS = authHeader();

export default function () {
    const res = http.get(`${BASE_URL}/anything`, {
        headers: AUTH_HEADERS,
        // Tag every request with the scenario slug too. `bench_scenario`
        // is already on every metric via `lib/options.js`, but keeping
        // it on the request as well makes per-URL drilldowns in the
        // raw stream JSON (when STREAM=1) trivially groupable.
        tags: { url: '/anything' },
    });

    classify(res);

    check(res, {
        'status is 200':                       (r) => r.status === 200,
        'response_body has json.method=GET':   (r) => {
            try { return JSON.parse(r.body).method === 'GET'; }
            catch { return false; }
        },
    });
}
