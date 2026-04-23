# tyk

Configurations for the tyk column. See
[`docs/GATEWAYS.md`](../../docs/GATEWAYS.md) for the canonical
gateway roster and uniform settings, and
[`docs/POLICIES.md`](../../docs/POLICIES.md) for the 10 canonical
policy profiles plus the p03-jwks-rs256-basic scenario track.

## Pinned image

```
tykio/tyk-gateway:v5.11.1
└─ sha256:225624f56be59a54614ff8ba88255fec1c430037a4f7232fc141d2615bdff598
```

Auxiliary images:

```
redis:7.4-alpine
└─ sha256:7aec734b2bb298a1d769fd8729f13b8514a41bf90fcdd1f38ec52267fbaa8ee6

nginx:1.27.3-alpine
└─ sha256:814a8e88df978ade80e584cc5b333144b9372a8e3c98872d07137dbf3b44d0e4
```

The nginx image is reused across the repo (it is the canonical
`nginx` gateway baseline) and here serves the JWKS sidecar on
`bench-net`.

## Layout

```
gateways/tyk/
├── README.md                 · you are here
├── docker-compose.yaml       · 4-service stack (backend + redis + jwks-server + gateway)
├── tyk.standalone.conf       · shared Tyk gateway config (file-based apps/policies)
├── _jwks-server/
│   └── nginx.conf            · static JWKS HTTP origin on bench-net
├── _policies/
│   └── policies.json         · bench-default-policy (permissive, ACL-only)
└── p03-jwks-rs256-basic/         · p03-jwks-rs256-basic scenario (NOT part of the matrix)
    ├── NOTES.md
    ├── setup.sh
    └── apis/
        └── p03-jwks-rs256-basic.json
```

The `_jwks-server/` and `_policies/` directories are **shared** —
every tyk profile that ships a file-based Classic API definition
reads them via the bind-mounts declared in `docker-compose.yaml`.
Profile-specific API definitions live under `<profile>/apis/`.

## Topology

The tyk column runs a 4-container stack on an isolated
`bench-net` bridge:

```
gwb-tyk  ◀── :9080 ──  host
  │
  ├── Redis           (gwb-tyk-redis, mandatory — Tyk OSS refuses to serve traffic without it)
  ├── JWKS server     (gwb-tyk-jwks-server, nginx serving _reference/jwks-rs256/jwks.json)
  └── Backend         (gwb-tyk-backend, go-httpbin)
```

Why each extra container is needed:

* **`redis`** — Tyk OSS initializes every API with session storage
  against Redis, regardless of whether the profile actually uses
  sessions. The gateway's `/hello` endpoint stays in
  `fail`/`warn` until the Redis pool reports healthy.
* **`jwks-server`** — the `p03-jwks-rs256-basic` scenario
  needs a JWKS reachable over HTTP. Tyk's `jwt_source` URL matcher
  is hard-coded to `^(http|https):` (no `file://` scheme), and the
  inline base64-PEM alternative has **no `kid` lookup**, which
  would collapse probe 3 of the scenario into a free PASS. A
  single-endpoint nginx on the private bench network gives us a
  realistic JWKS-over-HTTP shape without adding external
  dependencies.
* **`backend`** — the shared go-httpbin upstream; same binary used
  in every other gateway column.

For profiles that don't exercise JWT, `jwks-server` is
unnecessary overhead but harmless — it serves one static file and
is not wired into the request path unless the profile's API
definition references `jwt_source`.

## Status

**9 PASS, 2 PARTIAL PASS / 32 probes (27 PASS, 5 cosmetic FAIL)** on
`tykio/tyk-gateway:v5.11.1`. Every canonical capability is green —
the 5 failing probes are all the same hard-coded `mw_jwt.go` status
code (`400 Authorization field missing` / `403 Key not authorized`
in place of the canonical `401`), inherited by both p02-jwt and
p12-full-pipeline.

| Profile                 | Verdict                          | Probes  | Notes                                                                                              |
| ----------------------- | -------------------------------- | ------- | -------------------------------------------------------------------------------------------------- |
| p01-vanilla             | **PASS**                         | 4/4     | Catch-all proxy with file-based API def.                                                            |
| p02-jwt                 | **PARTIAL PASS 2/6** (landed)    | 2/6     | Native HMAC; 4 cosmetic FAILs on `400`/`403` rejection codes (see [p02 NOTES](./p02-jwt/NOTES.md)). |
| p04-rl-static           | **PASS**                         | 2/2     | Native `global_rate_limit` 1000/1s.                                                                 |
| p05-rl-endpoint         | **PASS**                         | 4/4     | Endpoint-level `extended_paths.rate_limit`.                                                         |
| p06-rl-dynamic-low      | **PASS**                         | 2/2     | JSVM per-IP session synth (10 rps/IP).                                                              |
| p07-rl-dynamic-high     | **PASS**                         | 3/3     | Same JSVM pattern at 100 rps/IP.                                                                    |
| p08-req-headers         | **PASS**                         | 3/3     | `transform_headers` (XFF drop pre-proxy).                                                           |
| p09-resp-headers        | **PASS**                         | 2/2     | `transform_response_headers`.                                                                       |
| p10-req-body            | **PASS**                         | 3/3     | Native `transform` + Sprig template (`unset` / `set`).                                              |
| p11-resp-body           | **PASS**                         | 3/3     | `transform_response` + Sprig template.                                                              |
| p12-full-pipeline       | **PARTIAL PASS 3/4** (landed)    | 3/4     | Full chain green on capability axis; 1 cosmetic 400/401 FAIL (see [p11 NOTES](./p12-full-pipeline/NOTES.md)). |
| `p03-jwks-rs256-basic`      | **PARTIAL PASS 1/3** (landed)    | 1/3     | Participates in `parity-gateway-all`; 2 cosmetic FAILs (`400`/`403`), capability verified.                     |

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix — native JWT middleware returns
`parity-gateway-all` and not part of the ranking matrix. See
[`docs/POLICIES.md § p03-jwks-rs256-basic`](../../docs/POLICIES.md#p03-jwks-rs256-basic)
for the scenario definition and
[`p03-jwks-rs256-basic/NOTES.md`](./p03-jwks-rs256-basic/NOTES.md) for the
full breakdown of tyk's native JWKS+RS256 shape, the 5.11.1
`getSecretFromURL` regression workaround, and the hard-coded
`400`/`403` deviations from `mw_jwt.go`.

Run the full core sweep:

```bash
make parity-gateway-all PARITY_GATEWAY=tyk
```

Run the p03-jwks-rs256-basic scenario directly:

```bash
make parity-gateway \
    PARITY_GATEWAY=tyk \
    PARITY_PROFILE=p03-jwks-rs256-basic
```

## Architectural note: body rewrites use native `transform`, not JSVM

p10-req-body and p12-full-pipeline both rewrite the JSON request body
using Tyk's native `extended_paths.transform` middleware (Go
`text/template` + bundled Sprig v3 `FuncMap`), NOT the otto JSVM
`pre` middleware Tyk's documentation reaches for first. The JSVM
worked for p09 in isolation but capped Tyk's effective throughput at
~830 rps (per-request `MiniRequestObject` (un)marshal + VM context
switch) — well below the 1000 rps `global_rate_limit` threshold
exercised by p11's burst probe, which then never accumulated enough
requests inside the 1 s window to trigger any 429s. Replacing the
JSVM with the native primitive (`unset` / `set` / `dict` / `hasKey` /
`mustToJson` from Sprig) eliminates the per-request VM cost and lands
p11's burst at the canonical `2xx≈999, 429≈201` split. Full
investigation in [`p12-full-pipeline/NOTES.md`](./p12-full-pipeline/NOTES.md).

The JSVM is still globally enabled in [`tyk.standalone.conf`](./tyk.standalone.conf)
because p06-rl-dynamic-low and p07-rl-dynamic-high need it for their
per-IP session synth pattern. It is dormant on every API definition
that does not populate `custom_middleware.{pre,post,response}[]`.
