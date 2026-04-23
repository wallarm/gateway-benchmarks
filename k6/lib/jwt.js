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

import { benchJwtValid, benchJwtValidRs256 } from './env.js';

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

// RS256 twin of validBearer(). Used by the s03-jwks-rs256-basic
// scenario, which exercises RS256 + JWKS kid-lookup instead of the
// shared-secret HS256 path. The runner script mints this via
// `scripts/gen-jwt-rs256.sh valid` when the scenario name matches
// `*jwks*`. An empty token is a hard error at scenario init time so
// a silent misconfiguration never feeds bogus 401s into the report.
export function validRs256Bearer() {
    const token = benchJwtValidRs256();
    if (!token) {
        throw new Error(
            '[k6/lib/jwt] BENCH_JWT_VALID_RS256 is empty. The scenario ' +
            'asks for a valid RS256 token but none was injected. The ' +
            "runner script (scripts/load-gateway.sh) sets it via " +
            "'gen-jwt-rs256.sh valid' on the host before invoking k6.",
        );
    }
    return `Bearer ${token}`;
}

export function authHeaderRs256() {
    return { Authorization: validRs256Bearer() };
}
