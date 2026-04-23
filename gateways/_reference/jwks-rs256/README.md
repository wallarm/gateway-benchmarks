# `jwks-rs256` — RS256 / JWKS reference assets

These files back the **`p03-jwks-rs256-basic` profile** — not
the canonical `p02-jwt` profile. The canonical p02 stays HS256 and
keeps using the assets under [`../jwt/`](../jwt/) and
[`../jwks/`](../jwks/); this directory exists purely so a gateway can
be exercised on the **RS256 + JWKS** axis as a dedicated profile
alongside the other eleven.

## Inventory

| Path            | Purpose                                                                                  |
|-----------------|------------------------------------------------------------------------------------------|
| `private.pem`   | RSA-2048 private key (PKCS#8, PEM). Public by design. **Signs tokens for parity probes.** |
| `public.pem`    | Matching RSA-2048 public key (SPKI, PEM).                                                |
| `jwks.json`     | Static JWKS containing **one JWK** derived from `public.pem`.                            |
| `kid.txt`       | Canonical `kid`: `bench-rs256-2026`. Every JWK in `jwks.json` and every token we mint carries this value. |

## Not secret

The RS256 private key is **deliberately public**, exactly like the
HS256 secret under [`../jwt/secret.txt`](../jwt/secret.txt) and the
TLS private key under [`../tls/`](../tls/). It lets anyone outside
Wallarm reproduce the p03-jwks-rs256-basic parity attestation bit for bit.
No production system has ever trusted this key; no production
hostname resolves to `bench.local`.

## Regenerating

```bash
cd gateways/_reference/jwks-rs256
# 1. New key pair
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out private.pem
openssl rsa -in private.pem -pubout -out public.pem

# 2. Derive JWKS (stdlib python + openssl; see the snippet below for the
#    canonical form we ship).
python3 - <<'PY'
import base64, json, re, subprocess
from pathlib import Path

mod_hex = subprocess.check_output(
    ["openssl", "rsa", "-pubin", "-in", "public.pem", "-modulus", "-noout"],
    text=True,
).strip().split("=", 1)[1]
exp_int = int(re.search(r"Exponent:\s+(\d+)",
    subprocess.check_output(
        ["openssl", "rsa", "-pubin", "-in", "public.pem", "-text", "-noout"],
        text=True,
    )).group(1))

def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

Path("jwks.json").write_text(json.dumps({
    "keys": [{
        "kty": "RSA", "use": "sig", "alg": "RS256",
        "kid": Path("kid.txt").read_text().strip(),
        "n":   b64url(bytes.fromhex(mod_hex).lstrip(b"\x00")),
        "e":   b64url(exp_int.to_bytes((exp_int.bit_length() + 7) // 8, "big")),
    }]
}, indent=2) + "\n")
PY
```

Rotating the key pair **will break every currently running parity
probe** until the JWKS is re-derived and the fixture tokens are
re-minted. Regenerate only when intentional.

## Why separate from `../jwks/`

[`../jwks/jwks.json`](../jwks/jwks.json) is an **HMAC-SHA-256 (kty=oct)**
JWKS; it mirrors the HS256 secret used by `p02-jwt`. Mixing an RSA
JWK into that file would change the canonical p02 binding across
every gateway, and that isn't what p03-jwks-rs256-basic is
for.

The new scenario (`p03-jwks-rs256-basic`) lives parallel to the core
matrix. It has its own fixture
([`fixtures/p03-jwks-rs256-basic.jsonl`](../../../fixtures/p03-jwks-rs256-basic.jsonl))
and its own token generator
([`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)),
both of which key off **this** directory.

## See also

- [`docs/POLICIES.md § p03-jwks-rs256-basic`](../../../docs/POLICIES.md)
  — the canonical description of `p03-jwks-rs256-basic`.
- [`scripts/gen-jwt-rs256.sh`](../../../scripts/gen-jwt-rs256.sh)
  — mints RS256 tokens using `private.pem` for `valid` / `unknown-kid`
  probes.
