# Policy Profiles

> Expansion of the 10 policy profiles from [TASK.md §4](../TASK.md) and their **parity requirements**.

## Principles

1. One profile — one aspect of functionality (TLS, auth, rate limit, body rewrite, Lua). Profiles **do not combine** — that would give 2^10 combinations, while we measure each aspect on its own.
2. **Parity**: given the same request, every gateway must either answer the same way or the chain is tagged as a **deviation** and excluded from the cell's ranking.
3. All concrete values (secrets, keys, rate-limit windows) are locked in `gateways/<gw>/pXX-.../config.yaml` and are parameterised from the same set of variables used by `scripts/parity-attestation.sh`.

## Profile list

| # | Name | Protocol | Type | Parity check |
|---|------|----------|------|--------------|
| p01 | **bypass** (baseline) | HTTP/1.1 plaintext | no policy | backend receives the request unchanged |
| p02 | **tls-terminate** | HTTPS → HTTP/1.1 | TLS termination | identical request body at the backend, TLS cert pinned |
| p03 | **header-auth** | HTTP/1.1 | require `X-Api-Key: <secret>` | 401 without the header, 200 with the correct one |
| p04 | **jwt-hs256** | HTTPS | HS256 validation with a fixed secret | 401 on invalid/expired, 200 on valid |
| p05 | **jwt-rs256** | HTTPS | RS256 validation with a fixed public key | idem |
| p06 | **rate-limit-ip** | HTTP/1.1 | 100 req/s per IP (window = 1s, rolling) | every gateway allows 100 req within 1s → 100 r/s steady |
| p07 | **rate-limit-key** | HTTPS | 100 req/s per `X-Api-Key` | same as p06 but keyed by header |
| p08 | **body-rewrite** | HTTPS | replace `"foo"` → `"bar"` in the request body | backend receives `"bar"` |
| p09 | **header-rewrite** | HTTP/1.1 | add `X-Gw: <name>`, drop `Cookie` | backend sees the addition and not the drop |
| p10 | **lua-plugin** *(wallarm+kong only)* | HTTP/1.1 | custom Lua: body + header rewrite | see `gateways/<gw>/p10/expected.txt` |

## Parity attestation contract

Before each cell `scripts/parity-attestation.sh` does:

```bash
for gw in wallarm nginx envoy kong apisix traefik tyk; do
  for profile in p01 p02 ... p10; do
    # send a fixed set of fixtures (from fixtures/p<XX>.jsonl)
    # compare each gateway's response against gateways/_reference/p<XX>.expected
    # write to reports/<run>/parity/p<XX>.json:
    #   { "gateway": "...", "profile": "...", "status": "OK" | "DEVIATION", "diff": [...] }
  done
done
```

The output becomes an artefact referenced from `manifest.json`. If a cell's status is `DEVIATION`, it is coloured differently in `report.html` and **does not contribute to the ranking**.

## Per-profile details

### p04 / p05 — JWT

The same JWT is used for every gateway:

```
Header:   { "alg": "HS256", "typ": "JWT" }  (p04)
          { "alg": "RS256", "typ": "JWT" }  (p05)
Payload:  { "sub": "bench", "exp": <far future> }
Secret:   "bench-hs256-secret-2026"          (public in README only, never production!)
RS256:    key pair in gateways/_reference/rs256/  (2048-bit, lives only in this repo)
```

These values are hardcoded: they are test keys that were never used in production.

### p06 / p07 — Rate limit

- Window: **1 second rolling** (not fixed), keyed per unique value.
- Limit: **100 req/s**.
- Above-limit behaviour: HTTP 429 with `Retry-After: 1`.
- Parity: after 120 requests within 1 second from the same IP, the gateway must return at least 15 × 429 (tolerance ±5). Otherwise → deviation.

### p08 — Body rewrite

- Request: `{"msg": "foo"}` (JSON, `Content-Type: application/json`)
- Expected at the backend: `{"msg": "bar"}` (echoed via `/anything`)
- Notes: exact match, no regex, no explicit Content-Length recompute (the gateway must do it).

### p10 — Lua

Only for gateways with a Lua runtime (Wallarm, Kong). Parity with Apache APISIX can be added later if needed.

Reference:

```lua
function execute(ctx)
  local body = ctx.request.body()
  body = body:gsub("foo", "bar")
  ctx.request.set_body(body)
  ctx.request.set_header("X-Gw", ctx.gateway.name)
end
```

The identical code is placed in `gateways/wallarm/p10-lua-plugin/policy.lua` and `gateways/kong/p10-lua-plugin/policy.lua`.

## Deviations

All known deviations are tracked in [GATEWAYS.md](./GATEWAYS.md#deviations) with a reason.

## Status

> Stub. Phase 3 in the roadmap. This file contains **only the specification**; the implementation in `gateways/*/p*/` and `scripts/parity-attestation.sh` lands in Phase 3.
