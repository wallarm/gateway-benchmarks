# tyk · p09-resp-headers

## Verdict

**PASS 2/2** on tyk 5.11.1 OSS.

| # | Probe                                                  | Verdict |
| - | ------------------------------------------------------ | ------- |
| 1 | client sees `X-Bench-Out`, no `Server` (with explicit upstream Server) | **PASS** |
| 2 | response-header drop is unconditional                  | **PASS** |

## Native primitive

`extended_paths.transform_response_headers` on the API definition's
version block — the response-side mirror of `transform_headers`:

```jsonc
{
  "extended_paths": {
    "transform_response_headers": [{
      "delete_headers": ["Server"],
      "add_headers":    { "X-Bench-Out": "1" },
      "path":           "{rest:.*}",
      "method":         "GET"
    }]
  }
}
```

`add_headers` injects client-visible headers; `delete_headers`
removes them from the outgoing response. Tyk evaluates both **after**
copying upstream headers into `responseWriter`, so even when the
upstream explicitly emits `Server: should-be-dropped` (probe 1 uses
go-httpbin's `/response-headers?Server=…`) the client sees nothing.
Tyk itself does not stamp a `Server: tyk` on responses, so there is
nothing else to clean up.

The wildcard path `{rest:.*}` makes the rule apply to every endpoint
the API serves, including `/get` and `/response-headers` which the
fixture targets.

## Files in this profile

| Path                  | Role                                                              |
| --------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`     | Tyk Classic API def with `transform_response_headers` add/delete  |
| `setup.sh`            | Readiness + API-loaded check + `X-Bench-Out` / `Server` smoke     |
| `NOTES.md`            | This document                                                     |
