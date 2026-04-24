# Security Policy

This repository is a benchmark harness, not a production gateway. The
primary security concern is therefore **integrity of the benchmark**,
not confidentiality of any secret it handles — there are no real
secrets in this tree (see the next section).

## Scope

We consider the following in-scope and welcome reports:

1. **Parity bypass** — a way to make the parity attestation pass while
   the gateway actually diverges from the canonical behaviour (e.g. a
   pattern that satisfies the probe but gives different answers under
   real load).
2. **Reproducibility bypass** — a way to produce two different
   rankings from the same `manifest.json` (same git SHA, same seed,
   same image digests).
3. **Resource-exhaustion in the orchestrator itself** — a crafted
   `cells.jsonl` / `matrix.csv` / k6 summary that makes `bench` crash,
   hang, or explode memory on the loadgen host.
4. **Supply-chain concerns** — a pinned dependency (image digest, Go
   module, k6 binary digest) that is actually something other than
   what the manifest claims.
5. **Documented-public secrets that turned out to leak somewhere they
   shouldn't** (an untagged copy of `bench.local` key committed into
   a production repo, for example) — see also the next section.

Out of scope:
- Generic vulnerabilities in the upstream gateway images we pull. File
  those with the respective vendor.
- Generic vulnerabilities in the vendored `go-httpbin` fork. File
  those upstream.

## What's *not* a secret (by design)

The following files are **intentionally public** — they exist so any
independent reviewer can reproduce parity attestation bit-for-bit:

| File | What it is |
|---|---|
| `gateways/_reference/jwt/secret.txt` | HS256 shared secret `bench-jwt-hs256-secret-2026` |
| `gateways/_reference/jwks/jwks.json` | JWKS derived from the HS256 secret (symmetric) |
| `gateways/_reference/jwks-rs256/private.pem` | RSA-2048 private key for the `p03-jwks-rs256-basic` supplemental |
| `gateways/_reference/jwks-rs256/public.pem` | Matching RSA-2048 public key |
| `gateways/_reference/jwks-rs256/jwks.json` | JWKS wrapping the RS256 public key |
| `gateways/_reference/tls/bench.key` | TLS private key for the `bench.local` self-signed cert |
| `gateways/_reference/tls/bench.crt` | Self-signed cert (`CN=bench.local`, SAN for `localhost` + `gateway` + `127.0.0.1`) |

No production system accepts any of these values. No production
hostname resolves to `bench.local`. Committing them publicly is
deliberate. Please do not file a security issue for "there is a
private key in the tree".

## Reporting a vulnerability

Please use **[GitHub Private Vulnerability Reporting](https://github.com/wallarm/gateway-benchmarks/security/advisories/new)**
for anything in-scope above. We'll acknowledge within **3 business
days** and follow up with a fix or a "won't fix" explanation within
**14 days**.

If private reporting on GitHub is unavailable to you, open a GitHub
Issue with the subject line `SECURITY:` and the absolute minimum
detail to make contact — we'll follow up privately from there. Don't
include proof-of-concept payloads in the public issue.

## Disclosure

We aim for **coordinated disclosure**: a security advisory lands in
the [Security tab](https://github.com/wallarm/gateway-benchmarks/security)
together with the fix commit. Reporters are credited in the advisory
unless they explicitly ask otherwise.
