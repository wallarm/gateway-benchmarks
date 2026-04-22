# envoy / p01-vanilla — notes

## Intent

First column cell for envoy in the benchmark matrix. A bare
catch-all proxy with no policy, used to confirm envoy comes up
clean against `gateway-benchmarks/backend` and that every baseline
uniform setting from `docs/GATEWAYS.md §Uniform settings` is
actually in effect before we start layering JWT / rate-limit /
header / body filters on top.

Pinned image:

```
envoyproxy/envoy:distroless-v1.32.6
  @sha256:569ad5b2503aca24c9f6af48c47449200afdb761bb4d1a021741d6d6692acf56
```

## Shape

```
loadgen (host)  →  envoy :9080  →  backend:8080 (go-httpbin)
```

- Single listener on `0.0.0.0:9080`, `reuse_port: true`, `codec_type:
  HTTP1`.
- Single HTTP filter chain: `envoy.filters.http.router` only — every
  future profile inserts its filter *before* the router.
- Single `STRICT_DNS` cluster `backend_cluster` → `backend:8080`,
  HTTP/1.1 upstream with per-connection keep-alive and 60 s idle.
- Admin on `0.0.0.0:9901`, published on host for debugging. No
  profile mutates envoy through it; envoy reloads by container
  restart when a profile swap mounts a different `envoy.yaml`.

## Uniform-setting checklist

| Setting (docs/GATEWAYS.md)          | envoy knob                                   |
|-------------------------------------|----------------------------------------------|
| HTTP/1.1 downstream                 | `codec_type: HTTP1`                          |
| Access log OFF                      | no `access_log:` list                        |
| Downstream keep-alive 60 s          | `common_http_protocol_options.idle_timeout`  |
| Max requests / connection 100 000   | `max_requests_per_connection: 100000`        |
| Request timeout 10 s                | `request_timeout: 10s` + `route.timeout: 10s`|
| Connect timeout 10 s                | `cluster.connect_timeout: 10s`               |
| Upstream keep-alive ON              | `typed_extension_protocol_options` + TCP KA  |
| Body buffering OFF                  | default — envoy streams bodies               |
| `reuseport` / SO_REUSEPORT          | `listener.reuse_port: true`                  |
| Path normalization OFF              | `normalize_path: false`, `merge_slashes: false` |
| Server header policy                | `server_header_transformation: OVERWRITE`    |

## Parity

Last local run against `fixtures/p01-vanilla.jsonl`:

```
==> parity: gateway=envoy profile=p01-vanilla
  ✓ PASS   GET /status/200 returns 200
  ✓ PASS   GET /anything echoes method
  ✓ PASS   POST /anything echoes body
  ✓ PASS   GET /bytes/1024 returns exactly 1024 bytes
==> envoy / p01-vanilla: PASS  (passed 4/4, skipped 0)
```

Report lives in `reports/<RUN_ID>/parity/envoy-p01-vanilla.json`.

## Deviations

None. envoy's vanilla behaviour is a clean passthrough on every
fixture path (status code, method echo, body echo, byte count).
