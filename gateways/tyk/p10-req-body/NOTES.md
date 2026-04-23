# tyk · p10-req-body

## Verdict

**PASS 3/3** on tyk 5.11.1 OSS.

| # | Probe                                                  | Verdict |
| - | ------------------------------------------------------ | ------- |
| 1 | gateway injects `$.bench.injected` and drops `$.secret`| **PASS** |
| 2 | rewrite works on an empty body object `{}`             | **PASS** |
| 3 | `Content-Length` is correct after rewrite              | **PASS** |

## Native primitive

Tyk Classic ships a Go-template-based [`transform`](https://tyk.io/docs/api-management/traffic-transformation/request-body)
middleware for request bodies, and Tyk wires the bundled [Sprig v3 `FuncMap`](https://masterminds.github.io/sprig/)
into every `text/template` it parses (gateway/api_definition.go
`APIDefinitionLoader.filterSprigFuncs` — only the env-leak pair
`env`/`expandenv` is stripped). Sprig provides exactly the helpers we
need to do JSON-aware dotted-path mutation without leaving the Go
runtime:

| Helper                          | Role                                                                |
| ------------------------------- | ------------------------------------------------------------------- |
| `unset DICT KEY`                | delete `KEY` from `DICT`, return the (mutated) dict                 |
| `set DICT KEY VALUE`            | set `KEY` in `DICT` to `VALUE`, return the (mutated) dict           |
| `dict K1 V1 K2 V2 …`            | construct a literal `map[string]any`                                |
| `hasKey DICT KEY`               | bool, true iff `DICT` has `KEY`                                     |
| `index DICT KEY`                | return `DICT[KEY]` (interface{}) — preserves the underlying map ref |
| `mustToJson VALUE`              | JSON-marshal `VALUE`, error out on failure                          |

The shared template lives at
[`../_shared/templates/p10_request_rewrite.tmpl`](../_shared/templates/p10_request_rewrite.tmpl)
(mounted into the gateway by `docker-compose.yaml` at
`/opt/tyk-gateway/middleware/bench-templates/p10_request_rewrite.tmpl`)
and is referenced by `apis/bench.json` as a single `transform` entry
on `POST {rest:.*}`:

```jsonc
"extended_paths": {
  "transform": [
    {
      "path": "{rest:.*}", "method": "POST",
      "template_data": {
        "template_mode":   "file",
        "template_source": "/opt/tyk-gateway/middleware/bench-templates/p10_request_rewrite.tmpl",
        "input_type":      "json",
        "enable_session":  false
      }
    }
  ]
}
```

The template body is six lines of pipeline, all Sprig:

```gotemplate
{{- $_ := unset . "secret" -}}
{{- if hasKey . "bench" -}}
{{-   $_ := set (index . "bench") "injected" true -}}
{{- else -}}
{{-   $_ := set . "bench" (dict "injected" true) -}}
{{- end -}}
{{- mustToJson . -}}
```

`unset` and `set` mutate their first argument in place AND return the
(now-mutated) dict; we pin the return to `$_` so it is not rendered
into the output stream. `mustToJson .` then serialises the entire
(still-the-same) `.` map back to JSON; `mw_transform.go` takes the
rendered bytes, replaces `r.Body` and recomputes `r.ContentLength`
on the way through (line 118-121 of `gateway/mw_transform.go` in
v5.11.1).

The `hasKey . "bench"` branch preserves any already-present sibling
fields under `.bench` — important for p11's probe 1, which ships
`{"bench":{"from_client":true}}` on the wire and expects both
`$.bench.from_client` AND `$.bench.injected` to survive on the
upstream-echoed body. Probe 1 of this profile uses the identical
body shape.

## Why not the JSVM `pre` middleware

Earlier iterations of this profile ran a JSVM `pre` middleware
(`body_rewrite_request.js`) that JSON-parsed `request.Body`, ran
`set_path` / `drop_path`, and re-stringified. That worked for p09
in isolation, but composing it into p11 (JWT + 1000 rps RL + body +
header + response transforms) revealed a structural problem: otto's
per-request overhead (MiniRequestObject (un)marshal + VM context
switch) caps Tyk's throughput at ~830 rps on the bench hardware —
below the 1000 rps `global_rate_limit` threshold. With the JSVM in
the chain, p11's burst probe could never accumulate enough requests
inside the 1 s rate-limit window to trigger 429s; the bucket
plateaued at ~830 tokens consumed per second, refilled at the same
rate, and the limiter never fired. Three runs back-to-back produced
exactly `2xx=1200, 429=0` instead of the expected ~1000/200 split.

Replacing the JSVM with the native `transform` primitive eliminates
the per-request VM cost end-to-end. After the migration:

* p09 still PASSes 3/3 (same template, identical contract, smaller
  per-request footprint)
* p11 lands `2xx=999, 429=201` on the burst probe — exactly the
  canonical 1000/200 split — and the only remaining FAIL on p11 is
  the documented cosmetic 400/401 mismatch from `mw_jwt.go`

The shared `_shared/middleware/body_rewrite_request.js` is no longer
referenced by any profile and was retired in the same change. The
historical commentary in [.notes/PROGRESS.md] documents the
investigation that surfaced the JSVM throughput cap.

## Why not `transform_jq`

Would let us write the rewrite as a one-liner of `jq`, but it is
gated on the `jq` Go build tag and `tykio/tyk-gateway:v5.11.1` ships
**without** that tag. Confirmed by inspecting
`gateway/mw_transform_jq_dummy.go` (the build-time stand-in when
`!jq`), which compiles into the public image. Not an option without
a custom build of Tyk, which would defeat the point of pinning the
upstream image.

## Files in this profile

| Path                                          | Role                                                              |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`                             | Tyk Classic API def with native `transform` (POST only)           |
| `setup.sh`                                    | Readiness + API-loaded check + bench.injected/secret smoke probe  |
| `NOTES.md`                                    | This document                                                     |

Shared with p11:

| Path                                              | Role                                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------- |
| `../_shared/templates/p10_request_rewrite.tmpl`   | Sprig template: `unset .secret`, `set .bench.injected true`, `mustToJson .`     |
| `../docker-compose.yaml` (volumes section)        | Mounts `_shared/templates` to `/opt/tyk-gateway/middleware/bench-templates`     |
