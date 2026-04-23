# tyk · p11-resp-body

## Verdict

**PASS 3/3** on tyk 5.11.1 OSS.

| # | Probe                                                  | Verdict |
| - | ------------------------------------------------------ | ------- |
| 1 | gateway adds `$.bench.injected` and drops `$.origin`   | **PASS** |
| 2 | response-body rewrite preserves other top-level fields | **PASS** |
| 3 | works for POST responses too                           | **PASS** |

## Native primitive

Tyk OSS Classic ships exactly one native primitive that can do
JSON-aware response-body mutation: `extended_paths.transform_response`
with a Go template. Tyk wires `text/template` together with the
[Sprig v3 `FuncMap`](https://masterminds.github.io/sprig/) on every
response-body transform, which means we get the four helpers we need
(`unset`, `set`, `dict`, `mustToJson`) without writing a single byte
of Lua, gRPC, or coprocess plumbing.

The template lives in
[`../_shared/templates/p11_response_rewrite.tmpl`](../_shared/templates/p11_response_rewrite.tmpl)
(mounted into the gateway by `docker-compose.yaml` at
`/opt/tyk-gateway/middleware/bench-templates/p11_response_rewrite.tmpl`)
and is referenced by `apis/bench.json` per HTTP method:

```jsonc
"extended_paths": {
  "transform_response": [
    {
      "path": "{rest:.*}", "method": "GET",
      "template_data": {
        "template_mode":   "file",
        "template_source": "/opt/tyk-gateway/middleware/bench-templates/p11_response_rewrite.tmpl",
        "input_type":      "json",
        "enable_session":  false
      }
    },
    { "path": "{rest:.*}", "method": "POST", "template_data": { /* same */ } }
  ]
}
```

The template body is three lines of pipeline, all Sprig:

```gotemplate
{{- $_ := unset . "origin"                       -}}
{{- $_ := set   . "bench" (dict "injected" true) -}}
{{- mustToJson . -}}
```

Both `unset` and `set` mutate their first argument *in place* and
return the (now-mutated) dict, which is why the return value is
discarded into `$_` rather than rendered into the output stream.
`mustToJson` then serialises the entire `.` map back to JSON; Tyk
takes the rendered bytes, swaps them in for the upstream body, and
recomputes `Content-Length` on the way out.

## Why not the obvious alternatives

* **JSVM `response` middleware** — Tyk Classic OSS dispatches the
  `custom_middleware.response` hook through the gRPC / Python
  *coprocess* driver, **not** through the otto-based JSVM that
  `enable_jsvm: true` enables. There is no `response` array entry
  the otto driver will run, so the same JSVM pattern that worked
  for [p09](../p10-req-body/NOTES.md) (`pre` middleware on the
  request body) is not available on the response side.
* **`transform_jq_response`** — would let us write the rewrite as a
  one-liner of `jq`, but it is gated on the `jq` Go build tag in the
  gateway, and `tykio/tyk-gateway:v5.11.1` ships **without** that
  tag (you can confirm with `docker run --rm
  tykio/tyk-gateway:v5.11.1 /opt/tyk-gateway/tyk version` — no
  `jq` flag in the build banner). Not an option without a custom
  build of Tyk, which would defeat the point of pinning the
  upstream image.
* **Virtual endpoint** — replacing the upstream proxy with a JS
  function that does its own `TykMakeHttpRequest` and mutates the
  response works but bypasses every other middleware (auth,
  rate-limit, transforms) and inverts the architecture: we would no
  longer be exercising the gateway's response chain, we would be
  exercising a hand-rolled JS proxy. Wrong shape for a parity bench.

## Subtle Sprig / template details

* `set`/`unset` are listed in the
  [Sprig dict reference](https://masterminds.github.io/sprig/dicts.html)
  and are wired into Tyk via `sprig.FuncMap()` (the text/template
  variant). `mustToJson` errors out on any field Tyk can't marshal,
  which is the safer of the two JSON helpers — `toJson` swallows
  marshal failures and returns `""`, which would silently produce
  an empty downstream body.
* `dict "injected" true` constructs `map[string]interface{}` directly,
  which means the injected `$.bench.injected` lands as a real
  JSON `true`, not the string `"true"`. The fixture asserts
  `$.bench.injected == true` (boolean), and our parity helper
  `assert_json_contains_value` compares `(.bench.injected | tostring)`
  against the literal string `"true"` — both routes produce the
  same string and the probe passes.
* `path: "{rest:.*}"` is a `gorilla/mux` wildcard; same pattern
  used in [p07](../p08-req-headers/NOTES.md) and
  [p08](../p09-resp-headers/NOTES.md). One `transform_response`
  entry per HTTP method is the smallest viable shape — adding
  HEAD/PUT/DELETE/PATCH would cost nothing but the fixture never
  exercises them.
* `enable_session: false` keeps the template input as just the
  decoded body (no `_tyk_meta` / `_tyk_context` injection). Adding
  session metadata into the template input would change the shape
  of `.` and break the `unset`/`set` chain.
* No `response_processors: [{name: "response_body_transform"}]`
  wrapper is needed — that requirement was lifted in Tyk 5.3, and
  we are on 5.11.1.

## Files in this profile

| Path                                          | Role                                                              |
| --------------------------------------------- | ----------------------------------------------------------------- |
| `apis/bench.json`                             | Tyk Classic API def with `transform_response` for GET + POST      |
| `setup.sh`                                    | Readiness + API-loaded check + GET/POST smoke probes              |
| `NOTES.md`                                    | This document                                                     |

Shared with p11:

| Path                                                    | Role                                                                          |
| ------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `../_shared/templates/p11_response_rewrite.tmpl`        | Sprig template: `unset .origin`, `set .bench`, `mustToJson .`                 |
| `../docker-compose.yaml` (volumes section)              | Mounts `_shared/templates` to `/opt/tyk-gateway/middleware/bench-templates`   |
