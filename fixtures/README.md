# fixtures — parity probes per policy profile

One file per profile. Every line is **one probe** serialised as JSON
(JSONL). The parity attestation script iterates through the probes and
verifies each `expect` block against the gateway's response (and,
where relevant, the backend's echo).

## Probe schema

```jsonc
{
  "name":        "human-readable probe name",
  "request": {
    "method":    "GET|POST|...",
    "path":      "/...",
    "headers": { "Header-Name": "value, with ${PLACEHOLDERS}" },
    "query":   { "key": "value" },
    "body":      "literal string OR"              // string form
    "body_json": { "any": "json" }                // object form
  },
  "expect": {
    "status":                200,                        // exact match
    "response_header_present": ["X-Bench-Out"],          // case-insensitive
    "response_header_absent":  ["Server"],
    "response_body_json_contains": { "$.json.x": "y" }, // JSONPath -> expected scalar
    "response_body_json_absent":   ["$.json.secret"],
    "backend_saw_header": { "X-Bench-In": "1" },         // via /anything echo
    "backend_missed_header": ["X-Forwarded-For"]
  }
}
```

Every key in `expect` is optional. A probe passes only if **all** of
its listed checks pass. A missing key simply means that assertion is
not run.

## Placeholders

| Placeholder                  | Resolved by                                     | Scenario                |
|------------------------------|-------------------------------------------------|-------------------------|
| `${JWT_VALID}`               | `scripts/gen-jwt.sh valid`                      | `p02-jwt`, `p12-full-pipeline` |
| `${JWT_EXPIRED}`             | `scripts/gen-jwt.sh expired`                    | `p02-jwt`               |
| `${JWT_WRONG}`               | `scripts/gen-jwt.sh wrong-secret`               | `p02-jwt`               |
| `${JWT_VALID_RS256}`         | `scripts/gen-jwt-rs256.sh valid`                | `p03-jwks-rs256-basic`      |
| `${JWT_UNKNOWN_KID_RS256}`   | `scripts/gen-jwt-rs256.sh unknown-kid`          | `p03-jwks-rs256-basic`      |
| `${BENCH_IP_N}`              | Nth IP from the dynamic RL pool                 | `p05`, `p06`            |
| `${BENCH_HOST}`              | Gateway host (e.g. `gateway.local`)             | — (future)              |

`scripts/parity-attestation.sh` performs the substitution before
dispatching each probe.

The RS256 placeholders are cached lazily, just like the HS256 ones — a
sweep that only touches HS256 fixtures never invokes the RSA
generator, and vice versa. Both generators read their canonical
material from `gateways/_reference/jwt/` (HS256) and
`gateways/_reference/jwks-rs256/` (RS256 + JWKS).

## Profiles that aren't simple probe-by-probe

`p03 rl-static`, `p05 rl-dynamic-low`, `p06 rl-dynamic-high`, and the
burst probe inside `p11 full-pipeline` require a **burst** (N requests
over T seconds from K distinct keys). Their fixtures therefore declare
one probe with `kind: "burst"` and the desired parameters; the script
turns that into a real parallel burst via `curl --parallel -K`, applies
`burst.headers` (for example `Authorization: Bearer ${JWT_VALID}`), and
then asserts the aggregate outcome.

## Files

```
fixtures/
├── p01-vanilla.jsonl
├── p02-jwt.jsonl                  (HS256 shared secret)
├── p04-rl-static.jsonl
├── p05-rl-endpoint.jsonl         (per-endpoint RL axis, parallel to p03)
├── p06-rl-dynamic-low.jsonl
├── p07-rl-dynamic-high.jsonl
├── p08-req-headers.jsonl
├── p09-resp-headers.jsonl
├── p10-req-body.jsonl
├── p11-resp-body.jsonl
├── p12-full-pipeline.jsonl
└── p03-jwks-rs256-basic.jsonl         (first-class profile in the
                                    12-profile matrix; RS256 + inline
                                    static JWKS; runs opt-in via
                                    `make parity-gateway
                                    PARITY_PROFILE=p03-jwks-rs256-basic`)
```

### p03-jwks-rs256-basic

All fixtures use a `pNN-` prefix and belong to the unified 12-profile matrix.
They exercise an axis that sits outside the 12-profile ranking matrix
and therefore:

- do not appear in `make parity-gateway-all`;
- have their own reference assets under `gateways/_reference/<slug>/`;
- are run explicitly by the user / orchestrator.

See [`docs/POLICIES.md § p03-jwks-rs256-basic`](../docs/POLICIES.md)
for the canonical list.
