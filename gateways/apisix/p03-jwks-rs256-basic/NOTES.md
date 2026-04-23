# apisix · p03-jwks-rs256-basic

> p03-jwks-rs256-basic (NOT part of the 12-profile matrix). See
> [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
> for the full contract.

## Verdict

**PASS 3/3** on `apache/apisix:3.15.0-debian`.

| Probe                                      | Expected | Observed | Verdict | Notes                                                                                                   |
| ------------------------------------------ | -------- | -------- | ------- | ------------------------------------------------------------------------------------------------------- |
| no `Authorization` header                  | `401`    | `401`    | PASS    | Rejected by `openid-connect` with `bearer_only: true`; body: `{"error":"unauthorized_request"}`.         |
| valid RS256 token, canonical `kid`         | `200`    | `200`    | PASS    | JWKS fetched from `oidc-server` on first request, cached; signature verified via `kid` index.            |
| valid RS256 signature, `kid=unknown-kid-…` | `401`    | `401`    | PASS    | `lua-resty-openidc.openidc_load_jwt_and_verify_crypto` returns `RSA key with id unknown-kid-2026 not found`. |

Run locally with:

```bash
make parity-gateway \
    PARITY_GATEWAY=apisix \
    PARITY_PROFILE=p03-jwks-rs256-basic
```

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` exercises the **RS256 + JWKS-by-`kid`** axis. It is
deliberately kept outside the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile (when it
  lands on the apisix column) stays **HS256** — that is the profile
  every gateway is compared on.
- This p03-jwks-rs256-basic scenario lives parallel to p02 so apisix's JWKS
  / RS256 capability can be measured **without reshaping p02's
  question** across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly with the command above.

The first iteration is deliberately minimal — JWKS served by a tiny
sidecar and three probes. Future iterations may add a
`remote_jwks`-over-TLS variant, an `unknown-kid-with-forged-signature`
probe, or explicit `aud` / `exp` / `nbf` checks once those axes are
pinned in the canonical fixture.

## Plugin choice — why `openid-connect`, not `jwt-auth`

APISIX 3.15 ships two built-in plugins that touch JWT validation.
Only one of them implements the axis this scenario measures.

### `jwt-auth` (rejected)

APISIX's native `jwt-auth` plugin accepts exactly **one** inline
`public_key` per Consumer and has **no JWKS support**. The upstream
[`apisix#12791`][apisix-12791] tracks JWKS support as an open feature
request. More importantly, even for the HS256/RSA single-key path,
the plugin does not perform `kid` lookup — every incoming token is
verified against the one configured key regardless of its header.
That collapses probe 3 into a spurious PASS: an attacker-forged
token signed with the real private key but carrying an unknown `kid`
would be accepted. This is the same trap tyk's PEM path falls into
(see [`gateways/tyk/p03-jwks-rs256-basic/NOTES.md`][tyk-notes]).

### `openid-connect` (used)

The [`openid-connect`][apisix-oidc] plugin wraps
[`lua-resty-openidc`][resty-openidc] and exposes the full JWKS +
`kid` code path via `use_jwks: true`. The interesting call path for
this scenario is:

```
access_phase
  └─ openid-connect.rewrite (bearer_only=true)
      └─ openidc.bearer_jwt_verify
          └─ openidc_load_jwt_and_verify_crypto
              └─ openidc_pem_from_jwk           ◀── JWKS fetch + kid index
              └─ jwt:verify (go-jose-alike)     ◀── RS256 signature check
```

The trade-off is that the plugin is shaped around OIDC discovery —
`discovery` MUST point at an OpenID Connect discovery document
(`/.well-known/openid-configuration`), **not** at a bare JWKS URL.
The plugin parses `jwks_uri` out of the discovery doc before it can
fetch keys. That is the reason for the `oidc-server` sidecar in the
shared compose file.

[apisix-12791]: https://github.com/apache/apisix/issues/12791
[apisix-oidc]: https://apisix.apache.org/docs/apisix/plugins/openid-connect/
[resty-openidc]: https://github.com/zmartzone/lua-resty-openidc
[tyk-notes]: ../../tyk/p03-jwks-rs256-basic/NOTES.md

## Why a second sidecar (`oidc-server`)?

The canonical JWKS is committed at
[`gateways/_reference/jwks-rs256/jwks.json`](../../_reference/jwks-rs256/README.md).
Tyk's JWKS sidecar (`_jwks-server`) serves the same file on
`bench-net`; apisix needs the **same** file plus a minimal OIDC
discovery document alongside it:

```
gwb-apisix ── discovery: http://oidc-server/.well-known/openid-configuration ──▶ gwb-apisix-oidc-server
  ▲                   │                                                               │
  │                   │         .jwks_uri: http://oidc-server/.well-known/jwks.json   │
  │                   ▼                                                               │
  │          JWT verification                                                         │
  │          (lua-resty-openidc)                                                      │
  │                                                                                   │
  └──── reads /.well-known/jwks.json ◀── bind mount: _reference/jwks-rs256/jwks.json
```

Both endpoints are served by a single `nginx:1.27.3-alpine` container
(the same image digest as the core nginx column and tyk's JWKS
sidecar — no new pull surface). Config:

- [`gateways/apisix/_oidc-server/nginx.conf`](../_oidc-server/nginx.conf)
  — whitelists exactly the two well-known paths; everything else is a
  hard 404.
- [`gateways/apisix/_oidc-server/openid-configuration.json`](../_oidc-server/openid-configuration.json)
  — a hand-crafted, minimal discovery document. `issuer` is pinned to
  `gateway-benchmarks` to match the JWT payload's `iss` claim (from
  [`gateways/_reference/jwt/payload-template.json`](../../_reference/jwt/payload-template.json));
  `jwks_uri` points at the sidecar's own JWKS endpoint.

This is **not** a deviation from the canonical scenario definition:
the canonical fixture only constrains the probe shape (three
statuses) and the reference material. How a gateway internally
ingests the JWKS — inline, local file, HTTP URL, or via OIDC
discovery — is a free axis. The drift guard in
[`setup.sh`](./setup.sh) enforces byte-for-byte equality between what
`oidc-server` serves and what `_reference/jwks-rs256/jwks.json`
contains, plus `issuer` / `jwks_uri` consistency across the
discovery doc.

## Standalone-mode bootstrap (`apisix.standalone.yaml`)

APISIX is deployed in **standalone** mode
(`deployment.role = data_plane`,
`role_data_plane.config_provider = yaml`) so the parity harness
doesn't need an etcd cluster or the Admin API. The bootstrap file
lives one level up:

- [`gateways/apisix/apisix.standalone.yaml`](../apisix.standalone.yaml)
  — mounted at `/usr/local/apisix/conf/config.yaml`, shared across
  every profile.

The one quirk worth calling out is the **plugin allow-list**. APISIX
ships ~80 built-in plugins and normally loads them all; our allow-list
is minimised to the primitives that the bench actually uses (core
matrix + this scenario). One entry in the list is not used by any
profile but is still mandatory:

```yaml
# apisix.standalone.yaml (excerpt)
plugins:
  - openid-connect        # this scenario
  - jwt-auth              # core p02-jwt (HS256)
  - limit-count           # core p03/p04
  - limit-req             # core p05/p06
  - proxy-rewrite         # core p07/p09
  - response-rewrite      # core p08/p10
  - serverless-pre-function
  - serverless-post-function
  - prometheus            # << required, see below
```

The `prometheus` entry is required even though no profile registers
it on a route. APISIX's nginx.conf template
([`cli/ngx_tpl.lua`][apisix-ngx-tpl]) declares the
`lua_shared_dict prometheus-cache` directive only when
`enabled_plugins["prometheus"] or enabled_stream_plugins["prometheus"]`
is true. Several default modules that load at worker init (notably
the `syslog` stream plugin, which is loaded regardless of the HTTP
allow-list) have a transitive `require` on
`apisix.plugins.prometheus.exporter`, which calls
`ngx.shared["prometheus-cache"]` at module scope. Without the
`prometheus` entry in the allow-list every worker logs
`lua_shared_dict "prometheus-cache" not configured` at boot. Listing
`prometheus` satisfies the template condition, the shared_dict gets
declared, and the transitive load succeeds. No prometheus behaviour
is exposed on any route.

[apisix-ngx-tpl]: https://github.com/apache/apisix/blob/3.15.0/apisix/cli/ngx_tpl.lua

## Native primitive contract

The realisation in [`apisix.yaml`](./apisix.yaml):

```yaml
plugins:
  openid-connect:
    client_id: bench-apisix                            # schema-required stub
    client_secret: bench-noop-stub-not-a-secret        # schema-required stub
    discovery: http://oidc-server/.well-known/openid-configuration
    bearer_only: true                                  # reject unauthenticated -> 401
    use_jwks: true                                     # JWKS + kid lookup
    token_signing_alg_values_expected: RS256           # pin to RS256
    realm: gateway-benchmarks
```

Five fields do the work:

1. `discovery` — URL of the OIDC discovery document. The plugin
   GETs this URL on first request, extracts `jwks_uri`, and caches
   both documents for `jwk_expires_in` seconds (default 86 400).
2. `bearer_only: true` — makes the plugin strictly require an
   Authorization header; without it the plugin would try to start an
   OIDC UA redirect flow (wrong shape for a gateway-only bench).
3. `use_jwks: true` — skip introspection, validate the JWT against
   the JWKS. `lua-resty-openidc`'s `bearer_jwt_verify` indexes the
   JWKS by the incoming token's header `kid`; unknown `kid` → reject
   (exactly probe 3's axis).
4. `token_signing_alg_values_expected: RS256` — pins the accepted
   algorithm. Mitigates alg-confusion (RS-to-HS) attacks even though
   the bench does not expose a shared HMAC key to the attacker.
5. `client_id` / `client_secret` — schema-required by the plugin.
   In `bearer_only: true` mode they are not used to validate tokens
   (no token-endpoint call happens); stub values are fine.

### `aud` claim — not validated in bearer-only mode

`lua-resty-openidc`'s `bearer_jwt_verify` does NOT check the `aud`
claim — audience verification lives only in the full
id_token-validation flow, which `bearer_only` bypasses. This is
consistent with the canonical JWT payload at
[`gateways/_reference/jwt/payload-template.json`](../../_reference/jwt/payload-template.json),
which also does not carry an `aud` claim. A future profile
scenario that pins `aud` can re-enable that check via a
`serverless-post-function` or by switching to the full OIDC flow.

Everything else (upstream STRICT_DNS to `backend:8080`, single
catch-all route) is byte-for-byte the shape a future `p01-vanilla`
would take, so the only axis the parity fixture can measure is the
JWT/JWKS primitive itself.

## Setup flow

`scripts/parity-gateway.sh` boots the stack, then
[`setup.sh`](./setup.sh):

1. **Wait for the data plane.** Polls `/anything` until any HTTP
   status code comes back (the catch-all route answers `401`
   immediately once the plugin chain is live — that is the
   readiness signal in `bearer_only` mode).
2. **Drift guard.** `docker exec`s into the `oidc-server` sidecar,
   fetches both `/.well-known/jwks.json` and
   `/.well-known/openid-configuration` locally, and compares:
   - `keys[0].n` and `keys[0].kid` against
     `_reference/jwks-rs256/jwks.json`
   - `issuer` against the JWT payload template's `iss` claim
   - `jwks_uri` against the canonical sidecar URL
3. **Smoke.** Three mini-probes mirroring the fixture. Strict on
   every status (no `FEATURE-MISSING` path is reachable on
   apisix 3.15).

No Admin-API mutation happens — the route + plugin binding are
materialised from `apisix.yaml` at container boot in standalone mode.

## Files in this profile

| Path                                            | Role                                                     |
| ----------------------------------------------- | -------------------------------------------------------- |
| `apisix.yaml`                                   | Declarative route + `openid-connect` plugin binding      |
| `setup.sh`                                      | Readiness + drift guard + 3-probe smoke                  |
| `NOTES.md`                                      | This document                                            |

Shared with every apisix profile:

| Path                                            | Role                                                     |
| ----------------------------------------------- | -------------------------------------------------------- |
| `../apisix.standalone.yaml`                     | Bootstrap config (standalone mode, plugin allow-list)    |
| `../_oidc-server/nginx.conf`                    | Static server for the two `.well-known` endpoints        |
| `../_oidc-server/openid-configuration.json`     | Hand-crafted OIDC discovery document                     |
| `../docker-compose.yaml`                        | 3-service stack: backend + oidc-server + gateway         |

Reference assets (repo-wide):

| Path                                            | Role                                                     |
| ----------------------------------------------- | -------------------------------------------------------- |
| `../../_reference/jwks-rs256/jwks.json`         | Canonical JWKS (one RSA-2048 key, `kid=bench-rs256-2026`) |
| `../../_reference/jwks-rs256/private.pem`       | Signing key for `scripts/gen-jwt-rs256.sh`               |
| `../../_reference/jwt/payload-template.json`    | Canonical JWT payload (`sub`, `role`, `iss`)             |
| `../../../scripts/gen-jwt-rs256.sh`             | RS256 token generator (`valid` / `unknown-kid`)          |

## Known limits

* **Eight `[error]`-level log lines per parity run.** The
  `openid-connect` plugin logs every rejection at `[error]` severity
  via `core.log.error()` in
  [`plugins/openid-connect.lua:612`][apisix-oidc-lua]. Probe 1
  emits `OIDC introspection failed: No bearer token found in
  request.` (5 occurrences — 3 from `setup.sh` smoke + 3 parity
  probes of which one overlaps with a retry), and probe 3 emits
  `RSA key with id unknown-kid-2026 not found` twice. These are the
  plugin's chosen log level for any rejection path; they are not
  errors in the bench sense (each line corresponds 1:1 with a probe
  that PASSed). No `[error]`-level line appears during the
  bootstrap phase.
* **Stream plugins cannot be disabled via the bootstrap config.**
  Setting `stream_plugins: []` in `apisix.standalone.yaml` is
  silently ignored by the standalone-mode loader (the boot log still
  shows `load_stream(): new plugins: {syslog, limit-conn, …}` with
  the upstream default set). That is why the `prometheus` entry in
  the HTTP plugin allow-list is still required even though none of
  our profiles use rate limiting or metrics export. A future APISIX
  release that consolidates the standalone-mode config paths may
  make this redundant.
* **Discovery document is hand-crafted.** No dynamic OP runs in the
  `oidc-server` sidecar. `authorization_endpoint`, `token_endpoint`
  and `userinfo_endpoint` exist in the JSON to satisfy
  `lua-resty-openidc`'s schema but are never dialed in the
  `bearer_only` flow. A future p03-jwks-rs256-basic scenario that needs a
  real UA flow would have to replace this sidecar with an actual
  OP image (e.g. `oauth2-proxy` or `dex`).
* **JWKS cache TTL = 86 400 s (`lua-resty-openidc` default).**
  Rotating the reference JWKS in-place and expecting apisix to pick
  up the change within seconds will not work. Restart the `gateway`
  container after a `_reference/jwks-rs256` rotation. The parity
  harness tears the stack down between profiles so this is not an
  issue during a run.
* **No `FEATURE-MISSING` exit code.** APISIX 3.15 ships
  `openid-connect` with RS256+JWKS natively; a failure here is a
  real failure. A hypothetical future APISIX drop of the plugin
  would flip `setup.sh` to return `42`, but that is not reachable
  today.

[apisix-oidc-lua]: https://github.com/apache/apisix/blob/3.15.0/apisix/plugins/openid-connect.lua

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical `kid`).
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`gateways/envoy/p03-jwks-rs256-basic/NOTES.md`](../../envoy/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenario on envoy (PASS 3/3 via `jwt_authn` +
  `local_jwks.inline_string`).
- [`gateways/tyk/p03-jwks-rs256-basic/NOTES.md`](../../tyk/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenario on tyk (PARTIAL PASS 1/3; cosmetic status-code
  divergence).
