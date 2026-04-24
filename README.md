# Gateway Benchmarks

> Reproducible, vendor-neutral performance benchmarks for production API gateways under a **policy × protocol × load** matrix.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Status: Phase 9 release staging](https://img.shields.io/badge/status-phase_9_release_staging-yellow.svg)](./ROADMAP.md)

<!-- v0.1.0 ANNOUNCEMENT — replace once the canonical AWS run is captured. Source: docs/release-notes/v0.1.0.md § Announcement snippet -->

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
- Reasonable external tuning of a competing gateway is accepted as a PR — see [`CONTRIBUTING.md § Gateway-tuning PRs`](./CONTRIBUTING.md#gateway-tuning-prs) and the [PR template](./.github/PULL_REQUEST_TEMPLATE.md).
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

**(11 ranking policy profiles × 4 load profiles) + (2 HTTPS scenarios × 4 load profiles) = 52 cells per gateway × 7 gateways = 364 cells per run** — plus the supplemental `p03-jwks-rs256-basic` capability scenario (parity-only, off-grid). See [TASK.md §7](./TASK.md).

## Quick Start — Local mode

> Requirements: Linux/macOS host, Docker ≥ 24, 8+ physical cores, 16 GB RAM, `make`, `go ≥ 1.23`.

Two independent scenarios. Pick one — don't mix them. The Makefile has a
preflight check that refuses to boot a second stack while another one is up
and tells you exactly which command clears it.

**Run the full matrix** (the default workflow):

```bash
git clone https://github.com/wallarm/gateway-benchmarks
cd gateway-benchmarks

make prereqs-check          # verify the environment
make perf-local-run         # parity → load → aggregate → manifest → report
```

The orchestrator brings per-cell stacks up and down by itself — no separate
`perf-local-up` is needed. Result: `reports/<run-id>/report.html`
(`bench run` calls `bench report` automatically; `make bench-report
BENCH_RUN_ID=<run-id>` and `make bench-report
BENCH_REPORT_COMBINE=run-a,run-b` are also available).

**Long-running smoke stack** (only when you want to poke a live gateway
by hand — parity, curl, logs):

```bash
make perf-local-up          # bring loadgen + gateway + backend up in separate namespaces
make perf-local-parity      # parity-check against localhost:9080
make perf-local-cycle-smoke # HTTP + HTTPS round-trip through the stack
make perf-local-down        # tear down (also cleans up any orphan gwb-<gw>* per-cell stacks)
```

## Quick Start — AWS mode

> Requirements: AWS credentials, `tofu` ≥ 1.7 (or `terraform` ≥ 1.6), ~$15 per full run.

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars    # set your CIDR and region
tofu init && tofu apply -auto-approve

cd ../..
make perf-aws-deploy        # provision the stack on all 3 EC2 hosts
make perf-aws-run           # run the matrix (same orchestrator)
make perf-aws-report        # render reports/<run-id>/report.html (bench report)
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
├── reports/          # output runs (local-only, never tracked — see docs/REPORT.md)
└── docs/             # ARCHITECTURE / POLICIES / LOAD-PROFILES / GATEWAYS / REPRODUCIBILITY / REPORT
```

## Documentation

- [TASK.md](./TASK.md) — PRD (mandatory properties of the benchmark)
- [ROADMAP.md](./ROADMAP.md) — phased implementation plan
- [CHANGELOG.md](./CHANGELOG.md) — versioned release notes
- [CONTRIBUTING.md](./CONTRIBUTING.md) — how to submit tuning PRs, what we review
- [SECURITY.md](./SECURITY.md) — security policy + what is and isn't a secret in this tree
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — local/AWS topology and network path
- [docs/POLICIES.md](./docs/POLICIES.md) — 11 ranking + 1 supplemental policy profiles, parity requirements
- [docs/LOAD-PROFILES.md](./docs/LOAD-PROFILES.md) — 4 load profiles
- [docs/GATEWAYS.md](./docs/GATEWAYS.md) — versions, digests, deviations
- [docs/REPORT.md](./docs/REPORT.md) — how to read the HTML report
- [docs/REPRODUCIBILITY.md](./docs/REPRODUCIBILITY.md) — manifest, seeds, tolerance, `bench compare-runs` gate
- [docs/CANONICAL-RUN-HANDOFF.md](./docs/CANONICAL-RUN-HANDOFF.md) — executable playbook for the AWS canonical sweep
- [docs/RELEASE.md](./docs/RELEASE.md) — maintainer release process
- [orchestrator/README.md](./orchestrator/README.md) — `bench` Go binary (Phases 6 + 7 + 8)

## License

Apache 2.0 — see [LICENSE](./LICENSE).
