# tyk · p08-req-headers

## Verdict

**PASS 3/3** on tyk 5.11.1 OSS.

| # | Probe                                                  | Verdict |
| - | ------------------------------------------------------ | ------- |
| 1 | gateway injects `X-Bench-In: 1` and drops `X-Forwarded-For` | **PASS** |
| 2 | `X-Forwarded-For` drop is unconditional (no inbound XFF)    | **PASS** |
| 3 | other client headers pass through unchanged                 | **PASS** |

## Native primitive

`extended_paths.transform_headers` on the API definition's version
block — each entry binds a `(path, method)` pair to a list of
`add_headers` / `delete_headers` operations applied to the upstream
request:

```jsonc
{
  "extended_paths": {
    "transform_headers": [{
      "delete_headers": ["X-Forwarded-For"],
      "add_headers":    { "X-Bench-In": "1" },
      "path":           "{rest:.*}",
      "method":         "GET"
    }]
  }
}
```

`path: "{rest:.*}"` — Tyk's path matcher uses Mux-style placeholders
to spell "match any suffix". The fixture probes `/headers`, not
`/anything`, so a literal `path: "/anything"` would not engage the
rewriter.

`add_headers` injects upstream-visible headers; `delete_headers`
removes them from the outgoing request. Both operate on the
canonical-MIME header form — `X-Forwarded-For`, not `x-forwarded-for`
— so casing matters.

### Why `X-Forwarded-For` actually drops cleanly here

Earlier APISIX / Kong work needed an out-of-band patch to suppress
`X-Forwarded-For` because their reverse proxies (built on OpenResty)
re-stamp it after the plugin chain. Tyk in 5.11.1 evaluates
`transform_headers.delete_headers` on `outreq.Header` **after** the
copy from inbound, so the deletion sticks: the upstream sees zero
`X-Forwarded-For` headers in both probe 1 (we send one inbound) and
probe 2 (we send none). No nginx-template patching, no JS
intervention, no sidecar — the native primitive carries the axis.

(Earlier notes on Tyk's p03-jwks-rs256-basic had assumed the standard Go
`httputil.ReverseProxy` XFF-append behaviour would dominate; the
empirical run showed otherwise. The shared
[`tyk.standalone.conf`](../tyk.standalone.conf) `_comment_xff_outbound`
docstring captured the worst-case plan; in practice Tyk happens to
wire `delete_headers` after its own XFF stamp and the deletion
holds.)

## Files in this profile

| Path                  | Role                                                              |
| --------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`     | Tyk Classic API def with `transform_headers` add/delete           |
| `setup.sh`            | Readiness + API-loaded check + smoke for `X-Bench-In` and XFF     |
| `NOTES.md`            | This document                                                     |
