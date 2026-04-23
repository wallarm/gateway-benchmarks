// k6/scenarios/s03-jwks-rs256-basic-http.js
//
// Scenario s03-jwks-rs256-basic-http (TASK §4 / docs/POLICIES.md § p03-jwks-rs256-basic):
//
//   Drives the `p03-jwks-rs256-basic` policy — RS256 JWT validation
//   against a static, inline JWKS keyed by `kid`. Measures the cost
//   of the asymmetric path over and above the HS256 baseline: parse
//   the Authorization header, base64url-decode the compact JWS, key
//   the lookup into the JWKS by the token's `kid` header, RSA
//   PKCS#1-v1.5 verify the signature over SHA-256, and check `exp`.
//
// HTTP path: GET /anything (same echo endpoint s01 uses).
// Body: none.
// Auth: `Authorization: Bearer <valid RS256 token with kid=bench-rs256-2026>`.
// The token is minted once on the host by
// `scripts/gen-jwt-rs256.sh valid` before k6 is invoked and passed in
// via BENCH_JWT_VALID_RS256; `lib/jwt.js` resolves it during the k6
// init phase, so token minting is explicitly not in the hot path —
// every iteration re-uses the same pre-minted bearer.
// Tags: bench_gateway / bench_policy / bench_scenario / bench_load /
// bench_run_id are auto-attached by `lib/options.js`; nothing extra
// needs to be set here.
//
// This scenario always sends a valid RS256 token with
// `kid=bench-rs256-2026`; the load phase measures the happy path
// (valid + known kid → 200). The unknown-kid rejection path
// (probe 3 → 401) is covered by parity attestation
// (fixtures/p03-jwks-rs256-basic.jsonl), not here.
//
// Expected signal:
//   - 100% of responses should be 2xx (the token is always valid and
//     its `kid` always resolves in the inline JWKS, so the gateway
//     has nothing to reject and the backend's /anything always
//     answers 200).
//   - The 5xx counter must stay at 0 on p1/p2/p3; p4 may surface
//     non-zero 5xx as the gateway saturates (same as s01).
//   - Tail-latency interest: p95 / p99 / p99.9 (the report generator
//     plots these per-gateway side by side).

import http from 'k6/http';
import { check } from 'k6';

import { targetUrl } from '../lib/env.js';
import { authHeaderRs256 } from '../lib/jwt.js';
import { classify } from '../lib/metrics.js';
import { options as resolvedOptions } from '../lib/options.js';

export const options = resolvedOptions;

// Resolved once at init (k6 init phase), not per-iteration — saves a
// trivial amount of work per request and matches how every other
// scenario will treat its base URL.
const BASE_URL = targetUrl();

// Pre-minted valid RS256 Bearer token, also resolved once at init
// (see `lib/jwt.js`). A missing / empty BENCH_JWT_VALID_RS256 throws
// a descriptive error before any traffic is generated, so a silent
// misconfiguration can never feed bogus 401s into the summary.
const AUTH_HEADERS = authHeaderRs256();

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
