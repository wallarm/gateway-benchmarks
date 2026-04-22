# Gateway Benchmarks

> Reproducible, vendor-neutral performance benchmarks for production API gateways under a **policy × protocol × load** matrix.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Status: Phase 3b in progress](https://img.shields.io/badge/status-phase_3b_in_progress-orange.svg)](./ROADMAP.md)

---

## TL;DR

We compare seven API gateways under **identical conditions** and let any independent reviewer:

1. Re-run the benchmark locally or on AWS with a single command.
2. Obtain a **byte-for-byte equivalent ranking** (within tolerance — see [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md)).
3. Verify that all gateways treat the same request the same way (**parity attestation**).
4. Inspect the full run manifest: image digests, git SHA, RNG seed, host info.

## Neutrality Disclaimer

This project is developed and maintained by **Wallarm, Inc.** — the author of one of the gateways under test. To neutralise the conflict of interest, we follow strict rules:

- All gateway configs, k6 scenarios, and infrastructure are **open and frozen at report release** (the git SHA is pinned in `manifest.json`).
- **Parity attestation** runs before every cell: the same request, the same JWT seed, the same rate-limit window — gateways either behave identically, or the cell is marked as a `deviation` and excluded from the aggregate.
- Reasonable external tuning of a competing gateway is accepted as a PR — see the [template](./.github/PULL_REQUEST_TEMPLATE.md) *(to be added in Phase 8)*.
- All deviations are documented in [docs/GATEWAYS.md](./docs/GATEWAYS.md) with a reason and an upstream reference.

## Gateways Under Test

| Gateway | Language | Role |
|---------|----------|------|
| [Wallarm API Gateway](https://github.com/wallarm/wallarm-api-gateway) | Rust | subject under test |
| NGINX                   | C                  | baseline |
| Envoy                   | C++                | baseline |
| HAProxy *(candidate)*   | C                  | baseline |
| Kong                    | Lua/OpenResty      | baseline |
| Apache APISIX           | Lua/OpenResty      | baseline |
| Traefik                 | Go                 | baseline |
| Tyk                     | Go                 | baseline |

10 **policy profiles** × 4 **load profiles** × two protocols (HTTP/1.1 plaintext and HTTP/1.1 TLS) — **336 cells per run** (see [TASK.md](./TASK.md)).

## Quick Start — Local mode

> Requirements: Linux/macOS host, Docker ≥ 24, 8+ physical cores, 16 GB RAM, `make`, `go ≥ 1.23`.

```bash
git clone https://github.com/wallarm/gateway-benchmarks
cd gateway-benchmarks

make prereqs-check          # verify the environment
make perf-local-up          # bring loadgen + gateway + backend up in separate namespaces
make perf-local-run         # run the full matrix (~45 min)
make perf-local-report      # produce HTML + CSV in reports/<timestamp>/
make perf-local-down
```

Result: `reports/<timestamp>_<sha>/report.html`.

## Quick Start — AWS mode

> Requirements: AWS credentials, `tofu` ≥ 1.7 (or `terraform` ≥ 1.6), ~$15 per full run.

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars    # set your CIDR and region
tofu init && tofu apply -auto-approve

cd ../..
make perf-aws-deploy        # provision the stack on all 3 EC2 hosts
make perf-aws-run           # run the matrix (same orchestrator)
make perf-aws-report        # pull raw data and render the report
make perf-aws-down          # tear down EC2 (edits tfvars and runs apply)
```

## Repository Layout

```
.
├── TASK.md           # PRD — what we measure and why
├── ROADMAP.md        # phased implementation plan
├── Makefile          # single entry point
├── backend/          # forked go-httpbin — a predictable upstream
├── gateways/         # per-gateway configs × policy profile
├── k6/               # load profiles and scenarios
├── orchestrator/     # Go binary driving the run
├── infra/
│   ├── local/        # docker-compose + resource pins
│   └── aws/          # Terraform (3 EC2 cluster PG)
├── scripts/          # prereqs, parity, deploy, fetch
├── reports/          # output runs
└── docs/             # ARCHITECTURE / POLICIES / LOAD-PROFILES / GATEWAYS / REPRODUCIBILITY / REPORT
```

## Documentation

- [TASK.md](./TASK.md) — PRD (mandatory properties of the benchmark)
- [ROADMAP.md](./ROADMAP.md) — phased implementation plan
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — local/AWS topology and network path
- [docs/POLICIES.md](./docs/POLICIES.md) — 10 policy profiles and parity requirements
- [docs/LOAD-PROFILES.md](./docs/LOAD-PROFILES.md) — 4 load profiles
- [docs/GATEWAYS.md](./docs/GATEWAYS.md) — versions, digests, deviations
- [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md) — manifest, seeds, tolerance

## Current Status

The project is in early phases. No benchmark runs yet — we are building the foundation.

- [x] Phase 1 — Skeleton (README, directories, license, lint CI)
- [x] Phase 2 — Synthetic backend (vendored `mccutchen/go-httpbin@v2.22.1`, static Docker image, smoke-tested)
- [x] Phase 3a — Parity foundation (canonical values, reference assets, fixtures, `make parity-check[-all]`)
- [~] Phase 3b — Per-gateway configs (7 gateways × 10 policy profiles)
    - [x] burst runner (p03 / p04 / p05) + `parity-gateway` lifecycle
      (now using `curl --parallel -K` for sustained 1200 rps bursts)
    - [x] `FEATURE-MISSING` short-circuit in `scripts/parity-gateway.sh`
    - [x] `wallarm / p01-vanilla` — 4/4 green against `wallarm/api-gateway:0.2.0`
    - [x] `wallarm / p02-jwt` — **FEATURE-MISSING** on 0.2.0 (no native
      `jwt_validation` policy in the public image)
    - [x] `wallarm / p03-rl-static` — 2/2 green, `ratelimit` policy with
      `rate=1000/1s`, sliding window
    - [x] `wallarm / p06-req-headers` — 3/3 green, `lua_runner` on
      `request_flow` (`+X-Bench-In`, `-X-Forwarded-For`)
    - [x] `wallarm / p07-resp-headers` — 2/2 green, `lua_runner` on
      `response_flow` (`+X-Bench-Out`, `-Server`)
    - [x] `wallarm / p08-req-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `request_flow` (`+$.bench.injected`,
      `-$.secret`, Content-Length recomputed)
    - [x] `wallarm / p09-resp-body` — 3/3 green, `lua_runner` +
      `cjson.safe` on `response_flow` (`+$.bench.injected`,
      `-$.origin`, Content-Length recomputed)
    - [ ] `wallarm / p04, p05, p10` (next iteration)
    - [ ] `nginx`, `envoy`, `kong`, `apisix`, `traefik`, `tyk` (subsequent iterations)
- [ ] Phase 4 — k6 load framework (4 profiles)
- [ ] Phase 5 — Infra (local + AWS 3-EC2)
- [ ] Phase 6 — Go orchestrator
- [ ] Phase 7 — Report generator
- [ ] Phase 8 — Quality gates + docs
- [ ] Phase 9 — Publication / v0.1.0

See [ROADMAP.md](./ROADMAP.md) for details.

## Contact

- Issues / Discussions: this repository
- Security: `security@wallarm.com`
- Wallarm API Gateway: https://github.com/wallarm/wallarm-api-gateway

## License

Apache 2.0 — see [LICENSE](./LICENSE).
