// k6/lib/env.js
//
// Single source of truth for every environment variable consumed by
// every k6 scenario or profile in the framework. The runner script
// (`scripts/load-gateway.sh`) is the canonical caller and sets these
// before invoking `k6 run`. The orchestrator (Phase 6) will set the
// same set verbatim.
//
// All readers in this file:
//   - return strictly-typed values (no leaky `undefined`),
//   - fail fast with a descriptive error if a required var is missing,
//   - have a documented default for every optional var.
//
// Any new env var must land here first, then in
// `scripts/load-gateway.sh`'s arg surface, then in `k6/README.md`'s
// "Environment surface" table — in that order.

function readRequired(name) {
    const value = __ENV[name];
    if (value === undefined || value === '') {
        throw new Error(
            `[k6/lib/env] required env var ${name} is not set; ` +
            `set it before invoking 'k6 run' (see scripts/load-gateway.sh).`,
        );
    }
    return value;
}

function readOptional(name, fallback) {
    const value = __ENV[name];
    if (value === undefined || value === '') {
        return fallback;
    }
    return value;
}

function readBool(name, fallback) {
    const value = readOptional(name, undefined);
    if (value === undefined) return fallback;
    return value === '1' || value.toLowerCase() === 'true';
}

function readInt(name, fallback) {
    const value = readOptional(name, undefined);
    if (value === undefined) return fallback;
    const parsed = Number.parseInt(value, 10);
    if (Number.isNaN(parsed)) {
        throw new Error(
            `[k6/lib/env] env var ${name}='${value}' is not an integer.`,
        );
    }
    return parsed;
}

// Target gateway URL (e.g. http://gateway:9080 inside bench-net, or
// http://localhost:9080 from the host). The runner sets the
// container-network form by default — bench-net resolves `gateway` via
// the service alias declared in every gateways/<gw>/docker-compose.yaml.
export const targetUrl = () => readRequired('BENCH_TARGET_URL').replace(/\/+$/, '');

// Target URL for the HTTPS scenarios (s13-vanilla-https,
// s14-full-pipeline-https). Must start with `https://` — a plain-HTTP
// URL here would produce a connection-reset avalanche the moment the
// first TLS ClientHello bytes hit the gateway's http parser, so the
// opt-in scenarios validate the scheme at init and fail fast.
//
// DEAD until Phase 5: the Phase 5 TLS plumbing (cert chain under
// `gateways/_reference/tls/`, `listen 443 ssl;` on each gateway
// config, `:8443` host-port binding in `docker-compose.yaml`) is the
// prerequisite that lets the runner actually point here; until that
// ships, the orchestrator leaves BENCH_TARGET_URL_HTTPS unset and s13
// / s14 throw at init — a clear trigger contract rather than silent
// dormancy. Trailing slashes are stripped for symmetry with
// targetUrl() so callers can always append `/<path>` without caring
// about the canonical form.
export const benchTargetUrlHttps = () => readOptional('BENCH_TARGET_URL_HTTPS', '').replace(/\/+$/, '');

// Which load profile is active for this run — one of:
//   p1-baseline, p2-sustained, p3-ramp, p4-stress
// `lib/options.js` switches on this to pick the k6 `options` object.
export const loadProfile = () => readRequired('BENCH_LOAD_PROFILE');

// Which policy profile + scenario this run is exercising. Both are
// strings the report generator (Phase 7) groups by; k6 itself only
// uses them as `tags` on every metric so summary JSONs are self-
// describing.
export const policyProfile = () => readRequired('BENCH_POLICY_PROFILE');
export const scenarioName  = () => readRequired('BENCH_SCENARIO');

// Which gateway is under test — used as a `tag` only, not as routing.
export const gatewayName = () => readRequired('BENCH_GATEWAY');

// Run identifier (timestamp slug). The runner injects this so all
// metrics from one cycle carry the same tag and the orchestrator can
// stitch them together post-run.
export const runId = () => readRequired('BENCH_RUN_ID');

// Master pseudo-random seed. Every randomness consumer (payload
// padding, IP pool index, JWT pool index in p03-jwks-rs256-basic scenarios)
// derives from this, so two runs with the same seed produce the same
// request stream on the wire. Default 42 to match the documented
// reproducibility convention.
export const runSeed = () => readInt('BENCH_RUN_SEED', 42);

// Pre-minted HS256 JWT for scenarios that need an Authorization
// header. The runner script invokes scripts/gen-jwt.sh on the host
// (k6 cannot shell out) and passes the result via env. Empty / unset
// is a hard error in scenarios that opt in via `requireJwt()` (see
// k6/lib/jwt.js); scenarios that don't need a token never read this.
export const benchJwtValid = () => readOptional('BENCH_JWT_VALID', '');

// Pre-minted RS256 JWT for the p03-jwks-rs256-basic scenario. Same
// contract as BENCH_JWT_VALID but signed with the canonical RS256
// private key (gateways/_reference/jwks-rs256/private.pem). Minted
// by `scripts/gen-jwt-rs256.sh valid` on the host; k6 never sees
// openssl. Empty / unset is a hard error in scenarios that opt in
// via `validRs256Bearer()`.
export const benchJwtValidRs256 = () => readOptional('BENCH_JWT_VALID_RS256', '');

// Stream every request's timing data to JSON when STREAM=1. Off by
// default because the file balloons fast (~50 MB / minute on a
// p4-stress run); the summary export is enough for ranking.
export const streamMetrics = () => readBool('BENCH_STREAM_METRICS', false);
