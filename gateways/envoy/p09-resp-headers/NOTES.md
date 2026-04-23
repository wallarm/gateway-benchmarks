# envoy / p09-resp-headers

Response-header transform: inject `X-Bench-Out: 1` on every response,
drop the `Server` header. Entirely native envoy — no Lua filter, no
third-party module. This is where envoy's out-of-the-box behaviour
differs most from nginx's and where the config matters most.

## Canonical contract

* `docs/POLICIES.md § p08` — response-side header transforms.
* `fixtures/p09-resp-headers.jsonl`:

  | Probe | Expect |
  | --- | --- |
  | `GET /response-headers?Server=should-be-dropped` | 200 + client sees `X-Bench-Out`, does NOT see `Server` (upstream injected one) |
  | `GET /get` | 200 + same (the drop is unconditional, works even when upstream emits no Server) |

Verdict: **PASS (2/2)** with the config below.

## Envoy primitive

Two knobs combined:

```yaml
# HCM level
server_header_transformation: PASS_THROUGH

# virtual_host level
response_headers_to_add:
  - append_action: OVERWRITE_IF_EXISTS_OR_ADD
    header:
      key: x-bench-out
      value: "1"
response_headers_to_remove:
  - server
```

### Why BOTH knobs are needed

`response_headers_to_remove: [server]` **on its own is not enough**.
Envoy's HCM evaluates `server_header_transformation` AFTER the
route-level header mutations, and its default value is `OVERWRITE`,
which unconditionally stamps `Server: envoy` on every outgoing
response — including ones we just stripped. Flipping it to
`PASS_THROUGH` removes that final write-back, so the stripping
on the virtual_host actually makes it to the wire.

The other two allowed values (`APPEND_IF_ABSENT` and the default
`OVERWRITE`) both re-introduce a Server header and were tested
empirically; both left `Server: envoy` in the response body headers
after `response_headers_to_remove` ran. Only `PASS_THROUGH` works.

### Ordering (why remove runs before transformation)

Envoy v3 proto documents the following fixed order for each
downstream-bound response:

1. Route-level `response_headers_to_add` / `_to_remove`.
2. Virtual_host-level `response_headers_to_add` / `_to_remove`.
3. Global `route_config` level `response_headers_to_add` /
   `_to_remove`.
4. HCM `server_header_transformation` + tracing / generated
   headers.

Step 2 strips Server; step 4 (with PASS_THROUGH) does not re-add
it. This matches the mapping we use in the nginx column
(`proxy_hide_header Server; server_tokens off; more_clear_headers
"Server";` — three knobs because nginx's default also re-stamps
after strip).

## Parity delta vs sibling columns

| Cell | Primitive |
| --- | --- |
| `nginx/p09-resp-headers` | `more_clear_headers "Server"` (ngx_headers_more, bundled with OpenResty image) + `add_header X-Bench-Out "1" always` |
| `envoy/p09-resp-headers` | `response_headers_to_remove: [server]` on virtual_host + `server_header_transformation: PASS_THROUGH` + `response_headers_to_add` for X-Bench-Out |
| `wallarm/p09-resp-headers` | `response_headers_add` / `response_headers_remove` in the `response_flow` policy DSL |

Different shapes, same verdict. Notably envoy's approach is the
simplest of the three: one HCM flag + two virtual_host fields, no
third-party module and no DSL.

## Why `/response-headers?Server=…` is in the fixture

go-httpbin's `/response-headers?Name=value` synthesises the given
headers on its response. Probe 1 exercises the path where the
upstream deliberately sets a Server header; probe 2 exercises the
unconditional drop path where no upstream Server is set. Together
they cover both "gateway cleans up after upstream" and "gateway
produces a clean response on its own" — the two invariants a
production TLS-offloading gateway has to hold.

## Deviations

None. Direct native-primitive mapping of the canonical policy.

## Files

* `envoy.yaml` — p01-vanilla base + `server_header_transformation:
  PASS_THROUGH` + virtual_host `response_headers_to_add` /
  `_to_remove`.
* `setup.sh` — HEAD probes both fixture endpoints and asserts
  `X-Bench-Out` is present / `Server` is absent before parity runs.
* `NOTES.md` — this file.
