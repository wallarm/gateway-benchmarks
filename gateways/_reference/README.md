# gateways/_reference — shared parity assets

Everything under this directory is **shared by every gateway**. A
gateway's config file (`gateways/<gw>/<profile>/...`) renders from
these assets, the parity attestation script reads them, and the run
manifest pins them by content hash.

Changing a value here means the benchmark asks a different question.
Do not change these files while a run is in flight.

## Inventory

| Path                                  | Purpose                                                       |
|---------------------------------------|---------------------------------------------------------------|
| `values.yaml`                         | Single source of truth — every constant used by the benchmark |
| `jwt/secret.txt`                      | HS256 shared secret (public by design, never production)      |
| `jwt/payload-template.json`           | Base JWT payload minted by `scripts/gen-jwt.sh`               |
| `jwks/jwks.json`                      | JWKS derived from `jwt/secret.txt` (used as JWT fallback)     |
| `tls/bench.crt` / `tls/bench.key`     | Self-signed cert for `bench.local` / `localhost` / `gateway`  |
| `bodies/p08-request-in.json`          | Client → gateway body for `p08 req-body`                      |
| `bodies/p08-request-out.json`         | Gateway → backend body for `p08 req-body`                     |
| `bodies/p09-response-in.json`         | Backend → gateway body for `p09 resp-body`                    |
| `bodies/p09-response-out.json`        | Gateway → client body for `p09 resp-body`                     |

## Not secret

The JWT secret and the TLS private key are deliberately public. They
let anyone outside Wallarm reproduce parity attestation bit for bit.
No production system has ever accepted `bench-jwt-hs256-secret-2026`
as a valid signing key and no production hostname resolves to
`bench.local`.

## Regenerating

```bash
# Regenerate the JWKS from jwt/secret.txt
SECRET=$(tr -d '\n' < gateways/_reference/jwt/secret.txt)
K=$(printf '%s' "$SECRET" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
jq --arg k "$K" '.keys[0].k = $k' \
  gateways/_reference/jwks/jwks.json \
  > gateways/_reference/jwks/jwks.json.new
mv gateways/_reference/jwks/jwks.json.new gateways/_reference/jwks/jwks.json

# Regenerate the TLS material
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout gateways/_reference/tls/bench.key \
  -out    gateways/_reference/tls/bench.crt \
  -days 36500 \
  -subj '/CN=bench.local/O=gateway-benchmarks' \
  -addext 'subjectAltName = DNS:bench.local, DNS:localhost, DNS:gateway, IP:127.0.0.1'
```

## See also

- [`docs/POLICIES.md`](../../docs/POLICIES.md) — how each asset is used
  per policy profile
- [`docs/GATEWAYS.md`](../../docs/GATEWAYS.md) — uniform settings and
  deviations per gateway
- [`scripts/gen-jwt.sh`](../../scripts/gen-jwt.sh) — mints probe JWTs
  for parity attestation and k6
