# `nginx / p08-req-headers` — compliance notes

**Current verdict on `nginx:1.27.3-alpine`**: `PASS (3/3)`.

## How each fixture probe is satisfied

| Probe                                               | nginx mechanism                                                     |
|-----------------------------------------------------|---------------------------------------------------------------------|
| Client sends `X-Forwarded-For: 198.51.100.7` → backend sees `X-Bench-In: 1`, misses `X-Forwarded-For` | `proxy_set_header X-Bench-In "1";` + `proxy_set_header X-Forwarded-For "";` |
| No `X-Forwarded-For` from the client → still injected + drop unconditional | Same directives — both fire per request regardless of what the client sent. |
| Unrelated `X-Client-Trace: abc-123` → reaches backend unchanged | No per-header `proxy_set_header` for `X-Client-Trace`, so nginx forwards it verbatim. |

## Mechanism

```nginx
proxy_set_header   Connection           "";
proxy_set_header   Host                 $http_host;
proxy_set_header   X-Forwarded-Proto    $scheme;
proxy_set_header   X-Bench-In           "1";    # inject
proxy_set_header   X-Forwarded-For      "";     # drop
```

Two mainline-nginx idioms at work:

* **"Empty value drops the header."** When the right-hand side of
  `proxy_set_header` is an empty string, nginx omits the header
  from the upstream request entirely rather than forwarding it as
  an empty value. This is the canonical way to strip a
  client-supplied header on mainline without needing Lua or
  `ngx_headers_more`.
* **Default is verbatim forwarding.** Any header the client sends
  that is *not* named in a `proxy_set_header` / `proxy_hide_header`
  pair passes through to the backend exactly as received. This is
  what the third fixture probe (`X-Client-Trace: abc-123`) relies
  on.

## Uniform-settings audit

Same ten rows as
[`p01-vanilla/NOTES.md`](../p01-vanilla/NOTES.md#uniform-settings-audit)
with two profile-specific additions in the `http {}` block (the
two `proxy_set_header` lines above). No deviations from
`docs/GATEWAYS.md § Uniform settings`.

## Deliberate non-defaults (beyond p01)

* **No `X-Real-IP` pass-through** in this profile. p01/p03/p05/p06
  all send `X-Real-IP: $remote_addr` to the upstream; p07
  intentionally does not, because the fixture is about
  client-supplied header manipulation and a gateway-synthesised
  `X-Real-IP` would pollute the echo surface. The Phase-4 k6
  profile for p07 will drive through the same config, so this
  stays consistent between parity and load runs.

## Not-yet-exercised

* The "drop side" is exercised only against `X-Forwarded-For`.
  Phase-4 and other gateways may want to also drop e.g. `Via` or
  `Forwarded`; the pattern scales trivially (`proxy_set_header
  <header> "";` per entry).

## Cross-gateway symmetry

The wallarm cell for p07 has the same behavioural contract but
implements it via `lua_runner` (`ctx.request.headers[...] = nil`),
because the Wallarm API Gateway does not yet ship a first-class
`header_transform` policy. nginx's `proxy_set_header` path is
strictly simpler and
strictly faster (no Lua interpreter); the fixture is target-
agnostic and asserts only observable header state, so both
implementations land at the same PASS verdict.

Tracking: [`docs/GATEWAYS.md § Deviations`](../../../docs/GATEWAYS.md#deviations).
