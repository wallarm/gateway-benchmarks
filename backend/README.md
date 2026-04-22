# backend — synthetic benchmark backend

The benchmark backend is [`github.com/mccutchen/go-httpbin`][upstream],
an MIT-licensed zero-config HTTP testing server by Will McCutchen. We
vendor it **unmodified** under [`upstream/`](./upstream) and build a
stripped, statically linked container on top.

| Item                 | Value                                        |
|----------------------|----------------------------------------------|
| Upstream version     | `v2.22.1`                                    |
| Upstream commit      | `f26ca5854f665e80255940d5aab7f119904c3875`   |
| Upstream license     | MIT — see [`upstream/LICENSE`](./upstream/LICENSE) |
| Vendored on          | 2026-04-16                                   |
| Go toolchain (build) | `golang:1.25-alpine`                         |
| Final image base     | `scratch` (fully static, non-root)           |

Full attribution is in [`NOTICE`](./NOTICE).

[upstream]: https://github.com/mccutchen/go-httpbin

## Why `go-httpbin`?

The backend has to be:

1. **Deterministic** — same request ⇒ same response shape and size, so
   we measure gateway overhead, not backend jitter.
2. **Language-agnostic** — the gateways under test are written in Rust,
   C, Go, C++ and Lua, so the backend must be trivially installable
   from any of them.
3. **Feature-rich** — we need body echo, header echo, deterministic
   byte streams, controlled latency and gzip/deflate so the same
   backend can drive every load profile.

`go-httpbin` satisfies all three and is already widely used for HTTP
testing, so reviewers can independently verify the backend is neutral.

## Endpoints exercised by the benchmark

| Endpoint             | Load profile / policy usage                          |
|----------------------|------------------------------------------------------|
| `GET  /status/200`   | Healthcheck, smoke, baseline                         |
| `GET  /get`          | Vanilla GET, header pass-through                     |
| `POST /post`         | Vanilla POST with body echo                          |
| `GET  /anything`     | Generic echo (method, headers, body)                 |
| `GET  /headers`      | Pure header echo — used by policy rewrite tests       |
| `GET  /bytes/{n}`    | Deterministic body of size `n` bytes                 |
| `GET  /status/{code}`| Forced status codes — used by the error taxonomy     |
| `GET  /delay/{s}`    | Controlled upstream latency — tail-latency scenarios |
| `GET  /gzip`         | gzip-encoded response                                |
| `GET  /deflate`      | deflate-encoded response                             |

The full endpoint list lives in [`upstream/README.md`](./upstream/README.md).

## Build the image

```bash
make backend-build
```

which runs:

```bash
docker buildx build \
  --platform linux/amd64 \
  --build-arg BUILD_DATE=<iso-8601> \
  --tag gateway-benchmarks/backend:v2.22.1 \
  --tag gateway-benchmarks/backend:latest \
  --load \
  backend/
```

The result is a single-binary image (`CGO_ENABLED=0`, `-trimpath`,
`-ldflags "-s -w"`) on top of `FROM scratch`, no shell and no package
manager. Size is roughly 10 MB.

## Run locally

```bash
make backend-run
```

Which starts the backend on `localhost:8080`. Smoke check:

```bash
curl -sS  http://localhost:8080/status/200 -o /dev/null -w '%{http_code}\n'
curl -sS  http://localhost:8080/anything -d 'hello' | head -c 200 ; echo
curl -sS  http://localhost:8080/bytes/1024 -o /dev/null -w '%{size_download}\n'
```

Expected output: `200`, a JSON echo starting with `{"args": ...}`, and
`1024`.

## Reproducibility

- The image is tagged with the upstream semver (`v2.22.1`) **and** a
  floating `latest` tag; orchestrator runs always resolve the tag to a
  SHA-256 digest and pin every subsequent run to it. See
  [`../docs/REPRODUCIBILITY.md`](../docs/REPRODUCIBILITY.md).
- Build-time `-ldflags -X` embed the upstream version, commit and
  build date into the binary, so `/version` in go-httpbin echoes the
  exact revision being benchmarked.
- The binary is static (`CGO_ENABLED=0`) and stripped (`-trimpath`,
  `-s -w`), which removes toolchain-specific paths and makes the build
  bit-for-bit reproducible for a given set of build args.

## Not here on purpose

- No custom endpoints are added.
- No upstream source files are patched.
- No gateway-specific tweaks (timeouts, gzip thresholds, static
  routes, …) are baked into the backend.

If a future parity test genuinely requires a new endpoint, it goes
into a *separate* Go file next to `upstream/` (never inside
`upstream/`) and gets called out in this README, in
[`../docs/GATEWAYS.md`][gw] and in the run manifest.

[gw]: ../docs/GATEWAYS.md
