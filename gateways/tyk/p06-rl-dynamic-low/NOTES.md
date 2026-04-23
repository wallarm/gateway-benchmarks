# tyk · p06-rl-dynamic-low

## Verdict

**PASS 2/2** on tyk 5.11.1 OSS.

| # | Probe                                              | Expected            | Observed                | Verdict |
| - | -------------------------------------------------- | ------------------- | ----------------------- | ------- |
| 1 | single request with single IP, below limit         | `200`               | `200`                   | **PASS** |
| 2 | 10 IPs × 15 rps × 3 s burst (~150 expected 429)    | ≥120×429 ±30        | 431×429 / 19×2xx        | **PASS** |

## Native primitive

Tyk Classic OSS has **no native primitive** that buckets on an
arbitrary request header — `global_rate_limit` keys per-API,
`extended_paths.rate_limit` keys per (path, method). The documented
Tyk pattern for "rate limit by client IP / by header" is per-key
sessions: Tyk's session-level rate limit DOES bucket per key, so the
implementation is "synthesise one key per IP and let session
rate-limiting do the work".

We implement that with a JSVM `pre` middleware shared across p05/p06
(see [`../_shared/middleware/per_ip_session.js`](../_shared/middleware/per_ip_session.js)):

```text
incoming request
  ├─ X-Real-IP: 10.0.0.7
  ↓
pre middleware (per_ip_session.js)
  ├─ key  := "bench_ip_r10_10_0_0_7"
  ├─ if first sighting:
  │     POST /tyk/keys/<key>  body={ rate:10, per:1, access_rights:{bench:{...}} }
  ├─ request.SetHeaders["Authorization"] = key
  ↓
AuthToken middleware (Tyk default for use_keyless=false)
  ├─ hashes the synthesised key (hash_keys=true), looks up the session
  ├─ session has rate:10 / per:1 → applies the bucket
  ↓
proxy → upstream
```

The cache (`seen_ips`) is a JSVM module-scope object: each Tyk worker
shares one otto VM per middleware file, so the cache persists across
requests within the gateway process. A stale entry after a Tyk
restart re-provisions the session via `/tyk/keys/<key>` (Tyk's PUT
semantics make that idempotent — the same key value rehashes to the
same Redis row).

### `BENCH_RL_RATE` lives in `config_data`, not in JS

The shared JS file reads `BENCH_RL_RATE` / `BENCH_RL_PER` from the
API definition's `config_data` block — Tyk Classic's only sanctioned
channel for per-API JSVM parameters. Keeping the rate value in
`apis/bench.json` (not buried in `_shared/middleware/per_ip_session.js`)
preserves the matrix-readability invariant: every cell-level value
lives in the cell's own files.

```jsonc
// apis/bench.json
{
  "config_data": { "BENCH_RL_RATE": "10", "BENCH_RL_PER": "1" },
  "custom_middleware": {
    "pre":    [{ "name": "per_ip_session", "path": "/opt/tyk-gateway/middleware/bench/per_ip_session.js" }],
    "driver": "otto"
  }
}
```

### Why not the obvious shape?

Several "more direct" shapes were tried and rejected:

| Shape                                                          | Why it fails                                                                                                  |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `auth_token.auth_header_name = "X-Real-IP"` + pre-create keys  | Forces ahead-of-time enumeration of the IP space — fine for 10 IPs (p05) but absurd for 50 000 IPs (p06).    |
| `id_extractor` with `extract_from: "header"`                    | Only works in coprocess (Python / Lua / gRPC) drivers — not available with `driver: "otto"` in OSS.           |
| Virtual endpoint with custom counter via `TykGetData`/`TykSetData` | Virtual endpoints **replace** the upstream — they cannot proxy to the bench backend, so the probe never sees the upstream's `/anything` echo. |
| `quota_max` per session                                         | Quota is a count, not a rate; `quota_renewal_rate` resets the count but does not enforce a sliding RPS window. |

The JSVM-pre + per-IP-session synthesis is the documented Tyk
recipe for this axis (it appears in
[issue #2471](https://github.com/TykTechnologies/tyk/issues/2471) and
in the JS plugin guide).

### Subtle JS details that bit us

* `TykMakeHttpRequest` — **lowercase `ttp`**. The all-caps
  `TykMakeHTTPRequest` spelling that some docs show is wrong and
  yields `ReferenceError: 'TykMakeHTTPRequest' is not defined`.
* `Domain` is mandatory in the request object. Without it Tyk's
  `net/http` call fails with `unsupported protocol scheme ""` and
  the synthesised key is never created. We point at
  `http://127.0.0.1:8080` because the JSVM runs in-process with the
  gateway listener.
* `request.SetHeaders["Authorization"]` (no `Bearer ` prefix) —
  Tyk's AuthToken middleware reads the raw header value as the key
  and hashes it; the prefix would be hashed in.
* `seen_ips` lives at module scope **outside** the
  `NewProcessRequest` closure, so it survives across requests in
  the otto VM.

## Files in this profile

| Path                                          | Role                                                              |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`                             | Tyk Classic API def with `custom_middleware.pre` + `config_data`  |
| `setup.sh`                                    | Readiness + API-loaded check + per-IP smoke probe                 |
| `NOTES.md`                                    | This document                                                     |

Shared with p06:

| Path                                          | Role                                                              |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `../_shared/middleware/per_ip_session.js`     | JSVM pre middleware: IP → synthesised session key                 |
