# envoy · p12-full-pipeline — implementer notes

Canonical spec: [`docs/POLICIES.md` § p11](../../../docs/POLICIES.md)  
Canonical fixture: [`fixtures/p12-full-pipeline.jsonl`](../../../fixtures/p12-full-pipeline.jsonl)

## What this profile asserts

A single round trip to `POST /anything` with a valid HS256 JWT must
exercise **every** transform the benchmark cares about, in one pass:

| Layer | Effect | Canonical profile it mirrors |
|---|---|---|
| JWT validation | 401 on missing / expired / forged token | [`p02-jwt`](../p02-jwt/) |
| service-wide rate-limit | 1000 rps refill, 200-request burst cap | [`p04-rl-static`](../p04-rl-static/) |
| request headers | add `X-Bench-In: 1`, drop `X-Forwarded-For` | [`p08-req-headers`](../p08-req-headers/) |
| response headers | add `X-Bench-Out: 1`, drop `Server` | [`p09-resp-headers`](../p09-resp-headers/) |
| request body | inject `$.bench.injected=true`, drop `$.secret` | [`p10-req-body`](../p10-req-body/) |
| response body | inject `$.bench.injected=true`, drop `$.origin` | [`p11-resp-body`](../p11-resp-body/) |

Plus the 1200-request burst probe that must emit ≥150 × 429 on a
valid-JWT flood — verifying that the rate limiter fires **before** the
JWT filter, not after.

## Filter-chain order (the whole story)

Envoy evaluates HTTP filters sequentially on the **request** path
(top-down) and reverse-sequentially on the **response** path
(bottom-up). `p11` threads six policies through that ordering in a
single chain:

```
  REQUEST ──▶  local_ratelimit  ──▶  buffer  ──▶  lua  ──▶  router  ──▶  upstream
                                                  │
                                                  ├─ JWT HS256 verify  (p02)
                                                  └─ request-body rewrite  (p09)

  upstream ──▶  router  ──▶  lua  ──▶  buffer (no-op)  ──▶  local_ratelimit (no-op)  ──▶ RESPONSE
                            │
                            └─ response-body rewrite  (p10)
```

Header transforms live **outside** the filter chain, on the
`virtual_host`. They run in envoy's dedicated header-mutation stage:
the `request_headers_to_*` stage runs after `lua` and immediately
before `router` hands off upstream; the `response_headers_to_*` stage
runs after the upstream response re-enters envoy and before the last
filter on the response path. That's why `p07`/`p08` transforms fire
on the same config as `p11` without any Lua help.

### Why `local_ratelimit` is position 1

**429 must fire before JWT verification.** The burst probe ships a
valid JWT on every one of 1200 requests, inviting the JWT filter to
do 1200 HMAC-SHA-256 computations on tokens we're about to reject.
With `local_ratelimit` first, ~900 of those requests never reach
Lua — the same shape nginx's `limit_req` (phase: preaccess) gives
the nginx column.

If we reversed the order (`lua → local_ratelimit`), the benchmark
would still PASS (both the 2xx count and the 429 count stay in the
fixture's tolerance band), but the hot path would carry wasted HMAC
work under flood. That's a real production-posture difference, and
matching nginx's phase layout keeps the parity contract honest.

### Why `buffer` is position 2

Envoy's Lua filter's `request_handle:body()` returns `nil` unless
something before it has buffered the full request body. The
`buffer` filter is that something — same primitive `p10-req-body`
uses standalone. Without it, the `p09`-equivalent request-body
rewrite silently no-ops on any non-empty POST.

Response-body buffering is **implicit** in envoy's Lua filter
(calling `response_handle:body()` installs an internal buffer as a
side effect) so no second `buffer` filter is needed on the response
path — the `p10` half of the chain works without it.

### Why `lua` is position 3

One Lua filter carries both phase callbacks:

* `envoy_on_request` — JWT verify (p02) then request-body rewrite
  (p09). On JWT failure, `request_handle:respond({":status"="401"}, body)`
  short-circuits the chain, so neither the buffer nor the router
  gets invoked and the 401 body + `WWW-Authenticate` envelope match
  [`gateways/envoy/p02-jwt/NOTES.md`](../p02-jwt/NOTES.md) exactly.
* `envoy_on_response` — response-body rewrite (p10), guarded by
  `rewrite_response_if_json` so a non-JSON upstream body (HTML error
  pages, streamed binary) passes through unchanged.

## The four pending knobs that deserve explanation

### 1. `server_header_transformation: PASS_THROUGH`

Without it, envoy restamps `Server: envoy` after the
`response_headers_to_remove: [server]` mutation runs, defeating the
drop. `PASS_THROUGH` is the same knob `p09-resp-headers` documents;
the whole p08 NOTES apply verbatim here.

### 2. `max_requests_per_connection: 100000`

Prevents envoy from rotating the upstream connection mid-burst,
which would confuse the rate-limit token bucket's sharing across
keep-alive connections. Same value every envoy profile uses since
`p01-vanilla`.

### 3. `max_request_bytes: 1048576` on the buffer filter

1 MiB ceiling — well above any realistic benchmark body (the
fixture POSTs ~80 bytes). On overflow envoy returns 413 Payload Too
Large BEFORE the Lua filter runs, which matches the `p10-req-body`
behaviour.

### 4. Token-bucket shape: `200 / 50 / 0.05s`

* `max_tokens: 200` — burst cap, equivalent to nginx's `burst=200`
* `tokens_per_fill: 50` + `fill_interval: 0.05s` — 1000 rps steady
  refill

This is the exact shape `p04-rl-static` uses. The 1200-req ASAP
burst against a cold bucket lands at ~250-340 × 2xx + ~860-950 ×
429, inside the fixture's `status_429_min=150, tolerance=50` band
and inside the nginx column's ±30-request observed variance.

## Lua source layout

The inline Lua string on the filter is deliberately short:

1. `package.path` prefix so `require("jwt_hs256")` and
   `require("body_rewrite")` resolve to `/etc/envoy/lualib/*.lua`
   (bind-mounted read-only from `gateways/envoy/_shared/lualib/`).
2. Two `require`s to pull the shared modules (see
   `_shared/lualib/` for the pure-Lua crypto + JSON stack).
3. Shared constants for the 401 envelope — same bytes as `p02-jwt`.
4. `envoy_on_request` — JWT verify, method guard, body rewrite.
5. `envoy_on_response` — body rewrite.

Method guard detail: `req:body():setBytes()` on `GET`/`HEAD`/`DELETE`
can fabricate HTTP/1.1 framing that corrupts the keep-alive pool.
We only rewrite bodies on `POST`/`PUT`/`PATCH`, matching what
`p10-req-body/NOTES.md` documents.

## Parity delta vs. nginx column

* **Body length recalculation.** Envoy's `buf:setBytes()` automatically
  updates `Content-Length`; the nginx column's OpenResty Lua has to
  recompute it manually (`ngx.req.set_header`). Neither column is
  "wrong" — the envoy API is simply tighter.
* **Server header suppression.** nginx never emits
  `Server: nginx` because `server_tokens off` was set way back in
  `p01-vanilla`'s base config; envoy emits it by default and we
  have to ask it not to. The `p08` comment block in
  [`p09-resp-headers/NOTES.md`](../p09-resp-headers/NOTES.md) covers
  this in depth.
* **Header-transform case.** Envoy lowercases every header key
  internally; it accepts both `x-bench-in` and `X-Bench-In` in
  config. The fixture asserts `X-Bench-In` verbatim because
  go-httpbin's `.headers` echo preserves whatever case was on the
  wire (HTTP/1.1 canonical form), and envoy ships the wire-canonical
  form on egress by default.
* **429 retry-after value.** Envoy's local_ratelimit lets you add
  `Retry-After: 1` via `response_headers_to_add` on the filter; the
  nginx column uses `add_header Retry-After 1 always`. Wire-observed
  bytes are identical.

## Verification

```bash
PARITY_GATEWAY=envoy PARITY_PROFILE=p12-full-pipeline make parity-gateway
```

Expected:

```
✓ PASS   full pipeline: JWT valid, RL below limit, all transforms applied
✓ PASS   full pipeline: missing JWT still 401
✓ PASS   full pipeline: expired JWT still 401
✓ PASS   full pipeline: rate limit kicks in above 1000 rps
         [burst: 1200x, 0s, 2xx≈300 429≈900 5xx=0]
verdict: PASS  (passed 4/4)
```
