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

| Placeholder      | Resolved by                            |
|------------------|----------------------------------------|
| `${JWT_VALID}`   | `scripts/gen-jwt.sh valid`             |
| `${JWT_EXPIRED}` | `scripts/gen-jwt.sh expired`           |
| `${JWT_WRONG}`   | `scripts/gen-jwt.sh wrong-secret`      |
| `${BENCH_IP_N}`  | Nth IP from the dynamic RL pool        |
| `${BENCH_HOST}`  | Gateway host (e.g. `gateway.local`)    |

`scripts/parity-attestation.sh` performs the substitution before
dispatching each probe.

## Profiles that aren't simple probe-by-probe

`p03 rl-static`, `p04 rl-dynamic-low`, `p05 rl-dynamic-high`, and the
burst probe inside `p10 full-pipeline` require a **burst** (N requests
over T seconds from K distinct keys). Their fixtures therefore declare
one probe with `kind: "burst"` and the desired parameters; the script
turns that into a real parallel burst via `curl --parallel -K`, applies
`burst.headers` (for example `Authorization: Bearer ${JWT_VALID}`), and
then asserts the aggregate outcome.

## Files

```
fixtures/
├── p01-vanilla.jsonl
├── p02-jwt.jsonl
├── p03-rl-static.jsonl
├── p04-rl-dynamic-low.jsonl
├── p05-rl-dynamic-high.jsonl
├── p06-req-headers.jsonl
├── p07-resp-headers.jsonl
├── p08-req-body.jsonl
├── p09-resp-body.jsonl
└── p10-full-pipeline.jsonl
```
