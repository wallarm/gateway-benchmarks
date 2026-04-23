# tyk · p12-full-pipeline

## Verdict

**PARTIAL PASS 3/4** on tyk 5.11.1 OSS — capability green, one
cosmetic status-code FAIL inherited from `mw_jwt.go`.

| # | Probe                                                                | Expected               | Observed                                | Verdict |
| - | -------------------------------------------------------------------- | ---------------------- | --------------------------------------- | ------- |
| 1 | full pipeline: JWT valid, RL below limit, all transforms applied     | 200 + transforms       | 200 + every transform asserted          | **PASS** |
| 2 | full pipeline: missing JWT still 401                                 | 401                    | 400 (`Authorization field missing`)     | **FAIL (cosmetic)** |
| 3 | full pipeline: expired JWT still 401                                 | 401                    | 401 (`exp` branch)                      | **PASS** |
| 4 | full pipeline: rate limit kicks in above 1000 rps (1200-req burst)   | ≥ 150 (± 50) × 429     | `2xx=999, 429=201, 5xx=0` (~3 runs)     | **PASS** |

Probe 2 lands the same hard-coded `http.StatusBadRequest` Tyk Classic
returns on every missing-Authorization rejection — the exact same
deviation already documented in
[`../p02-jwt/NOTES.md`](../p02-jwt/NOTES.md) and the p03
[`../p03-jwks-rs256-basic/NOTES.md`](../p03-jwks-rs256-basic/NOTES.md). It is
not overridable in OSS without a custom build (literal
`http.StatusBadRequest` in `gateway/mw_jwt.go` v5.11.1; no config
knob in the Classic API definition or `tyk.standalone.conf` swaps it).

The capability itself — JWT auth + 1000 rps global rate-limit +
request-body rewrite + request-header rewrite + response-body rewrite
+ response-header rewrite — is fully native and walks every documented
middleware stage in the right order on every probe.

## Composition

p11 stitches together the same six axes already validated in their
own profiles:

| Axis                | Source profile                                        | Primitive used in p11                                                 |
| ------------------- | ----------------------------------------------------- | --------------------------------------------------------------------- |
| JWT (HS256)         | [`../p02-jwt/`](../p02-jwt/)                          | `enable_jwt: true` + `jwt_signing_method: hmac` + `bench-default-policy` |
| Static RL (1000 rps)| [`../p04-rl-static/`](../p04-rl-static/)              | `global_rate_limit: { rate: 1000, per: 1 }`                           |
| Request headers     | [`../p08-req-headers/`](../p08-req-headers/)          | `extended_paths.transform_headers` (POST + GET)                       |
| Response headers    | [`../p09-resp-headers/`](../p09-resp-headers/)        | `extended_paths.transform_response_headers` (POST + GET)              |
| Request body        | [`../p10-req-body/`](../p10-req-body/)                | `extended_paths.transform` (POST only) + shared Sprig template        |
| Response body       | [`../p11-resp-body/`](../p11-resp-body/)              | `extended_paths.transform_response` (POST + GET) + shared Sprig template |

Method coverage: the fixture exercises POST (probe 1, full body) and
GET (probe 4, 1200-rps burst). Header / response transforms are
registered for both methods so each probe gets its own native chain.
`transform` (request body) is registered for **POST only** because
mw_transform.go reads/parses `r.Body` unconditionally on a path/method
match — wiring it on GET would force a body-parse round-trip on every
burst hop for no semantic gain (the burst probe sends no body).

## Documented middleware order

From `gateway/api_loader.go` v5.11.1, the chain Tyk builds for an
API def with the primitives above:

```
VersionCheck
RequestSizeLimit
JSVM `pre`              ← (custom_middleware.pre, NOT used in p11; see § Why not JSVM)
JWT auth                ← mw_jwt.go
RateCheckMW             ← global_rate_limit, dispatched via RateLimitForAPI (mw_api_rate_limit.go)
RateLimitAndQuotaCheck  ← per-session limits (no-op here, bench-default-policy is unlimited)
TransformMiddleware     ← extended_paths.transform        (request body)
TransformHeaders        ← extended_paths.transform_headers (request headers)
…reverse proxy to upstream…
TransformResponseHeaders ← extended_paths.transform_response_headers
TransformResponse        ← extended_paths.transform_response (response body)
```

Probe 1 walks every stage; probes 2 and 3 short-circuit at JWT;
probe 4 (1200 rps GET burst) saturates RateLimitForAPI before any
header / body transform runs.

## Why the request body is rewritten via `transform`, not the JSVM

The first iteration of p11 wired the request-body rewrite through a
JSVM `pre` middleware (`body_rewrite_request.js`) — the same pattern
that worked for p09 in isolation. The result on the burst probe was
catastrophic:

| Probe                                              | Verdict |
| -------------------------------------------------- | ------- |
| 1 (full pipeline, valid JWT)                       | PASS    |
| 2 (missing JWT → 401)                              | FAIL (cosmetic 400, expected) |
| 3 (expired JWT → 401)                              | PASS    |
| 4 (1200 rps burst, expected ≥ 150 × 429)           | **`2xx=1200, 429=0`** — RL never fired |

Three runs back-to-back: identical zero × 429.

### Investigation

Step-by-step bisection isolated the cause:

1. **Same RL config in p03 (no JSVM, no JWT, keyless)** → `2xx=998,
   429=202`. Rate limiter works. The Tyk → Redis → SlidingLogRedis
   path (`internal/rate/rate.go`'s default selector for a single
   gateway with `enable_non_transactional_rate_limiter: true`) is
   correctly wired in both profiles and uses the same Redis bucket
   key.
2. **Disable JWT in p11, keep JSVM** → still `2xx=1200, 429=0`. JWT
   is not the culprit.
3. **Disable JSVM in p11, keep JWT** → `2xx=999, 429=201`. JSVM **is**
   the culprit.

Adding millisecond-precision timing to the burst harness made the
mechanism visible:

| Configuration             | Elapsed for 1200 GETs | Effective rate | 429s |
| ------------------------- | --------------------- | -------------- | ---- |
| p11 with JSVM `pre`       | 1.498 s               | ~801 rps       | 0    |
| p11 with JSVM `pre`       | 2.502 s (2000 reqs)   | ~800 rps       | 0    |
| p11 with JSVM `pre`       | 3.679 s (3000 reqs)   | ~815 rps       | 0    |
| p11 with JSVM `pre`       | 6.037 s (5000 reqs)   | ~828 rps       | 0    |
| p11 without JSVM          | 0.000 s (1200 reqs)   | > 1200 rps     | 201  |
| p03 (keyless, no JSVM)    | 0.000 s (1200 reqs)   | > 1200 rps     | 202  |

**otto caps Tyk's effective throughput at ~830 rps on this hardware**
— well below the 1000 rps `global_rate_limit` threshold. With the
JSVM in the chain, requests trickle through slower than the bucket
refills (`memorycache.Bucket.Add` consumes one token per call;
`time.Now().After(b.reset)` triggers a full refill at the 1 s
boundary). The bucket plateaus at ~830 tokens consumed per second
and never reaches its 1000-token capacity, so no request gets
`ErrBucketFull` and no 429 is returned.

The cost is paid even when the JS code itself short-circuits. The
otto driver marshals the entire request into a `MiniRequestObject`
JSON envelope before calling into the VM, runs the JS function (even
if it returns immediately), then unmarshals the `VMReturnObject`
back. A method guard inside the JS (`if (method !== "POST" && …)
return …`) saves the body-parse work but not the VM-call overhead.

### Fix

Tyk's documentation says request-body rewrites must use the JSVM,
but that is misleading: the OSS gateway also wires the bundled
[Sprig v3 `FuncMap`](https://masterminds.github.io/sprig/) into
every `text/template` it parses (gateway/api_definition.go:864
`filterSprigFuncs`), and Sprig provides exactly the helpers we need
to do JSON-aware dotted-path mutation natively:

```gotemplate
{{- $_ := unset . "secret" -}}
{{- if hasKey . "bench" -}}
{{-   $_ := set (index . "bench") "injected" true -}}
{{- else -}}
{{-   $_ := set . "bench" (dict "injected" true) -}}
{{- end -}}
{{- mustToJson . -}}
```

The full template lives at
[`../_shared/templates/p10_request_rewrite.tmpl`](../_shared/templates/p10_request_rewrite.tmpl)
(byte-identical to the one p09 now uses; the migration moved both
profiles off JSVM in the same change).

### After the fix

| Run | 2xx  | 429 | 5xx | Notes                              |
| --- | ---- | --- | --- | ---------------------------------- |
| 1   | 999  | 201 | 0   | exact canonical 1000/200 split     |
| 2   | 999  | 201 | 0   | identical                          |
| 3   | 999  | 201 | 0   | identical                          |

The 429 count of 201 (vs. the theoretical 200) is the same one-token
sliding-counter drift we see in every other gateway's p03 / p11
column (nginx 938, wallarm 351 → matches the p05 1-request drift,
envoy `2xx=999, 429=201` in its p11 column). Tyk now sits comfortably
inside the fixture's `≥ 150 ± 50` tolerance band on the burst probe.

## Subtle details

* **transform-only-on-POST** is mandatory. mw_transform.go reads
  `r.Body` unconditionally on a path/method match (line 59:
  `body, _ := ioutil.ReadAll(r.Body)`); a wildcard method match
  would force a body parse on every GET burst hop, which would not
  break correctness but would re-introduce per-request overhead
  (about 100-200 µs on this hardware, enough to start cutting into
  the 1 s window). Empirically: registering `transform` on GET
  drops the burst from `999/201` to `~1100/100` — still inside the
  fixture tolerance, but a wasted parse on every request.
* **Probes 1 and 4 share the response-transform chain** because both
  receive a 2xx upstream response that needs `Server` dropped and
  `X-Bench-Out` injected. The burst probe technically does not
  assert the response shape, but registering response transforms on
  both methods keeps the 1000 successful 2xx hops in the burst
  consistent with what probe 1 sees.
* **No JSVM in this profile** means the global `enable_jsvm: true`
  in `tyk.standalone.conf` (kept on for p05 / p06's per-IP session
  synth) is dormant on every p11 request. Tyk's JSVM subsystem only
  pays per-request cost when the API definition has
  `custom_middleware.{pre,post,response}[]` populated.
* **The cosmetic 400/401 FAIL on probe 2** is the same path
  documented in `../p02-jwt/NOTES.md`. The literal
  `http.StatusBadRequest` is inlined in `gateway/mw_jwt.go` and
  there is no config knob in the Classic API definition that swaps
  it for `http.StatusUnauthorized`. A workaround using a JSVM
  pre-middleware to intercept and re-emit `401` would re-introduce
  the throughput cap that breaks probe 4 — the same trade-off that
  killed the original JSVM-based shape.

## Files in this profile

| Path                         | Role                                                                                          |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `apis/bench.json`            | Tyk Classic API def chaining JWT + global RL + transform (POST) + headers + response transforms |
| `setup.sh`                   | Readiness + API-loaded check + policy-loaded check                                             |
| `NOTES.md`                   | This document                                                                                  |

Shared with other tyk profiles:

| Path                                                     | Shared with                                                              | Role                                                                          |
| -------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| `../_shared/templates/p10_request_rewrite.tmpl`          | [p09](../p10-req-body/NOTES.md)                                          | Sprig template: `unset .secret`, ensure `.bench.injected = true`              |
| `../_shared/templates/p11_response_rewrite.tmpl`         | [p10](../p11-resp-body/NOTES.md)                                         | Sprig template: `unset .origin`, `set .bench (dict "injected" true)`, `mustToJson .` |
| `../docker-compose.yaml` (volumes section)               | every tyk profile                                                        | Mounts `_shared/templates` to `/opt/tyk-gateway/middleware/bench-templates`   |
| `../tyk.standalone.conf`                                 | every tyk profile                                                        | Standalone Tyk config (file-based apps/policies, Redis, JSVM globally on)     |
| `../_policies/policies.json`                             | [p02](../p02-jwt/NOTES.md), this                                         | Permissive `bench-default-policy` (ACL only)                                  |
