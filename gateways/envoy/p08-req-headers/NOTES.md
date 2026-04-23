# envoy / p08-req-headers

Request-header transform: inject `X-Bench-In: 1`, drop
`X-Forwarded-For`. Entirely native envoy — no Lua filter, no sidecar.

## Canonical contract

* `docs/POLICIES.md § p07` — request-side header transforms.
* `fixtures/p08-req-headers.jsonl`:

  | Probe | Expect |
  | --- | --- |
  | `GET /headers` with client-sent `X-Forwarded-For` | 200 + backend saw `X-Bench-In: 1`, did NOT see `X-Forwarded-For` |
  | `GET /headers` without `X-Forwarded-For` | 200 + same (drop is unconditional) |
  | `GET /headers` with `X-Client-Trace: abc-123` | 200 + backend saw `X-Client-Trace: abc-123` (unrelated headers pass through) |

Verdict: **PASS (3/3)** with the config below.

## Envoy primitive

The envoy v3 proto exposes two fields on every `virtual_host` /
`route` for exactly this use case:

```yaml
route_config:
  virtual_hosts:
    - name: backend_vh
      request_headers_to_add:
        - append_action: OVERWRITE_IF_EXISTS_OR_ADD
          header:
            key: x-bench-in
            value: "1"
      request_headers_to_remove:
        - x-forwarded-for
```

The transforms run in the HCM's header-mutation stage — after the
router matches but before the filter chain forwards to the upstream
cluster. This places the transform AFTER any `request_headers_to_add`
on an enclosing route and BEFORE the Router's own synthetic
`x-envoy-*` headers, matching what nginx's
`proxy_set_header` idiom does at the `http` / `server` scope.

### Why `OVERWRITE_IF_EXISTS_OR_ADD` and not `APPEND_IF_EXISTS_OR_ADD`

Envoy offers four `append_action` values
(`APPEND_IF_EXISTS_OR_ADD`, `ADD_IF_ABSENT`,
`OVERWRITE_IF_EXISTS_OR_ADD`, `OVERWRITE_IF_EXISTS`). If a client
ships `X-Bench-In: 0`, the APPEND variant produces
`X-Bench-In: 0,1` (comma-joined), and the fixture's
`backend_saw_header.X-Bench-In == "1"` assertion fails. `OVERWRITE_IF_EXISTS_OR_ADD`
guarantees the backend sees exactly `X-Bench-In: 1` regardless of
what (if anything) the client sent. This matches nginx's
`proxy_set_header X-Bench-In "1"` semantics (mainline nginx always
overwrites on `proxy_set_header`; there is no "append" variant).

### Why virtual_host, not route

The fixture only exercises `/headers`, but the real-world intent
is a service-wide transform. Putting the fields on the virtual_host
covers every current and future route in one place. Mapping note to
the nginx column: nginx's `proxy_set_header` at the `http {}` level
has the same scope — apply to every `location` unless a `location`
overrides it. No route in this bench overrides the header transform.

### Case-insensitive matching

Envoy normalizes every incoming HTTP/1.1 header to lowercase at the
HCM layer (`normalize_headers: true` is implicit). We therefore spell
`x-forwarded-for` / `x-bench-in` lowercase in the remove/add lists
— matching the on-the-wire form the router sees. `X-Forwarded-For`
in the config would also work because the match is case-insensitive
per RFC 7230 §3.2, but lowercase is the convention envoy docs use
and the one most likely to survive a future proto tightening.

## Parity delta vs sibling columns

| Cell | Primitive |
| --- | --- |
| `nginx/p08-req-headers` | `proxy_set_header X-Bench-In "1"` + empty-string drop of `X-Forwarded-For` (mainline directive) |
| `envoy/p08-req-headers` | `request_headers_to_add` / `request_headers_to_remove` on virtual_host (native v3 proto) |
| `wallarm/p08-req-headers` | `request_headers_add`/`request_headers_remove` in the `request_flow` policy DSL |

All three shapes converge on the same fixture verdict. Envoy's
extra `x-envoy-*` headers (`x-envoy-expected-rq-timeout-ms`,
`x-envoy-original-path`, etc.) are not asserted by the fixture;
they are neither added nor removed by this profile. If a future
probe needs a perfectly clean surface, `router`'s
`suppress_envoy_headers: true` can silence them in one switch —
we deliberately leave envoy's default debug-friendly shape here
since none of the p07 probes touch that axis.

## Deviations

None. Direct native-primitive mapping of the canonical policy.

## Files

* `envoy.yaml` — p01-vanilla base + `request_headers_to_add`
  + `request_headers_to_remove` on the virtual_host.
* `setup.sh` — waits for data plane then asserts the add/drop
  invariants with two `curl /headers` probes.
* `NOTES.md` — this file.
