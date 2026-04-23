# `envoy / p03-jwks-rs256-basic` — p03-jwks-rs256-basic scenario notes

**Verdict on `envoyproxy/envoy:distroless-v1.32.6`**: `PASS (3/3)`.

## What this scenario is — and is NOT

`p03-jwks-rs256-basic` is a policy profile in the 12-profile matrix that exercises the
**RS256 + static inline JWKS** axis. It is deliberately kept outside
the 12-profile matrix:

- The canonical [`p02-jwt`](../p02-jwt/NOTES.md) profile (when it lands
  on the envoy column) stays **HS256**: that is the profile every
  gateway is compared on.
- This p03-jwks-rs256-basic scenario lives parallel to p02 so envoy's JWKS /
  RS256 capability can be measured **without reshaping p02's question**
  across every other gateway.
- It does not appear in `make parity-gateway-all`. It is invoked
  explicitly:

  ```bash
  make parity-gateway \
      PARITY_GATEWAY=envoy \
      PARITY_PROFILE=p03-jwks-rs256-basic
  ```

The first iteration is deliberately minimal — **static inline JWKS**
and three probes. A future iteration may add a `jwks_uri` variant (via
envoy's `remote_jwks`), an `unknown-kid-with-forged-signature` probe,
or explicit audience / subject checks.

## Native primitive

Envoy ships a first-class JWT filter: [`envoy.filters.http.jwt_authn`][jwt-authn]
(config proto: [`extensions.filters.http.jwt_authn.v3.JwtAuthentication`][proto]).
It implements the full JWT/JWKS verification flow natively — no Lua,
no sidecar, no plugin registry. RS256 is supported out of the box, as
is static JWKS via `local_jwks.inline_string` or `local_jwks.filename`.

The realisation in [`envoy.yaml`](./envoy.yaml):

```yaml
http_filters:
  - name: envoy.filters.http.jwt_authn
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.jwt_authn.v3.JwtAuthentication
      providers:
        bench_rs256_provider:
          issuer: gateway-benchmarks     # from payload-template.json
          forward: true                  # keep token visible upstream
          local_jwks:
            inline_string: |
              {"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"bench-rs256-2026","n":"…","e":"AQAB"}]}
      rules:
        - match: { prefix: "/" }
          requires: { provider_name: bench_rs256_provider }
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

Everything else (listener on `:9080`, HCM uniform settings,
`backend_cluster` STRICT_DNS to `backend:8080`) is byte-for-byte
identical to [`p01-vanilla/envoy.yaml`](../p01-vanilla/envoy.yaml) so
the only axis the parity fixture can measure is the JWT/JWKS primitive
itself.

[jwt-authn]: https://www.envoyproxy.io/docs/envoy/v1.32.6/configuration/http/http_filters/jwt_authn_filter
[proto]: https://www.envoyproxy.io/docs/envoy/v1.32.6/api-v3/extensions/filters/http/jwt_authn/v3/config.proto

## Inline vs mounted JWKS — why inline for the first iteration

The reference JWKS is committed at
[`gateways/_reference/jwks-rs256/jwks.json`](../../_reference/jwks-rs256/README.md);
envoy could consume it either via `local_jwks.filename` (a bind-mount)
or `local_jwks.inline_string` (a byte-literal embedded in
envoy.yaml). This profile uses `inline_string` for three reasons:

1. **Shared `docker-compose.yaml` stays untouched.** Bind-mounting
   `gateways/_reference/jwks-rs256/jwks.json` into the envoy container
   would require a volume entry in
   [`gateways/envoy/docker-compose.yaml`](../docker-compose.yaml), which
   is shared across every envoy profile. A mount that is only needed
   by one p03-jwks-rs256-basic scenario has no business living in the shared
   compose file.
2. **No filesystem plumbing for reviewers.** A reader landing on
   `envoy.yaml` can see the JWKS in place without chasing three files.
3. **Drift is trivial to guard.** The RSA modulus (`n`) is 342 chars
   of base64url that are uniquely determined by the private key. The
   drift guard in [`setup.sh`](./setup.sh) simply proves the reference
   modulus appears verbatim in envoy.yaml; if a future rotation of the
   reference assets forgets to refresh the inline JWKS, the guard
   fails loudly before a single probe runs:

   ```bash
   REFERENCE_N=$(jq -r '.keys[0].n' "${JWKS_FILE}")
   grep -qF "\"n\":\"${REFERENCE_N}\"" "${ENVOY_YAML}" \
       || fail "drift guard: envoy.yaml is out of sync with ${JWKS_FILE}"
   ```

A future `jwks-rs256-remote` scenario will exercise the
`remote_jwks` + `cache_duration` path; that is an orthogonal axis
(JWKS rotation, HTTP fetch errors, TTL semantics) and deserves its
own scenario rather than mutating this one.

## Probes

The three probes in
[`../../../fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl):

| # | Probe                                                            | Expected | Envoy error message (body)              |
|---|------------------------------------------------------------------|----------|-----------------------------------------|
| 1 | No `Authorization` header                                        | `401`    | `Jwt is missing`                        |
| 2 | `Authorization: Bearer <RS256 token, kid=bench-rs256-2026>`      | `200`    | —                                        |
| 3 | `Authorization: Bearer <RS256 token, kid=unknown-kid-2026>`      | `401`    | `Jwt verification fails: Jwks doesn't have key to match kid or alg from Jwt` |

Probe 3 is the one that makes this scenario meaningful: the token's
signature IS valid against the canonical private key, so a verifier
that just tries every key in the JWKS would accept it; a verifier that
correctly uses the `kid` as an index into the JWKS must reject. envoy
does the correct thing.

## No admin-API binding (vs wallarm)

Unlike [`wallarm/p03-jwks-rs256-basic/setup.sh`](../../wallarm/p03-jwks-rs256-basic/setup.sh),
this `setup.sh` performs no runtime binding — the filter is baked into
envoy.yaml and activated at `docker compose up`. Consequently:

- No `FEATURE-MISSING` exit code is possible for this profile on
  `envoyproxy/envoy:distroless-v1.32.6`. The filter ships in the
  upstream binary.
- Drift vs the reference JWKS is a **FAIL**, not a FEATURE-MISSING.
  The inline JWKS belongs to the profile's static config; keeping it
  in sync is a maintenance concern, not a capability question.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — canonical description of this scenario and why it is separate
  from p02.
- [`gateways/_reference/jwks-rs256/README.md`](../../_reference/jwks-rs256/README.md)
  — reference assets (private/public key, JWKS, canonical kid).
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — RS256 token generator for `valid` and `unknown-kid`.
- [`gateways/wallarm/p03-jwks-rs256-basic/NOTES.md`](../../wallarm/p03-jwks-rs256-basic/NOTES.md)
  — sibling scenario on wallarm: native `jwt_validation` against a
  from-source `WALLARM_IMAGE` (PASS 3/3); the `setup.sh` short-
  circuits to `FEATURE-MISSING` as a sanity guard if the supplied
  image doesn't ship `jwt_validation`.
