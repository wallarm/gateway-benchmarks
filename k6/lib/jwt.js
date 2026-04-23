// k6/lib/jwt.js
//
// JWT helpers. k6 cannot exec arbitrary commands inside a scenario,
// so token minting happens on the host before `docker run grafana/k6`
// is invoked: the runner script calls `scripts/gen-jwt.sh valid`,
// pipes the result into the BENCH_JWT_VALID env var, and we just
// surface it here.
//
// Splitting "mint" from "consume" this way keeps every k6 image
// pristine (no openssl in the loadgen container) and makes the JWT
// pipeline auditable from outside k6 (`gen-jwt.sh` is the same script
// the parity attestation uses, so the token shape is byte-for-byte
// identical between parity and load runs).
//
// Scenarios that need a token call `validBearer()` once at module
// load time (k6 init phase); a missing or empty token raises a clear
// error before any traffic is generated.

import { benchJwtValid } from './env.js';

export function validBearer() {
    const token = benchJwtValid();
    if (!token) {
        throw new Error(
            '[k6/lib/jwt] BENCH_JWT_VALID is empty. The scenario asks ' +
            'for a valid HS256 token but none was injected. The runner ' +
            "script (scripts/load-gateway.sh) sets it via 'gen-jwt.sh " +
            "valid' on the host before invoking k6.",
        );
    }
    return `Bearer ${token}`;
}

export function authHeader() {
    return { Authorization: validBearer() };
}
