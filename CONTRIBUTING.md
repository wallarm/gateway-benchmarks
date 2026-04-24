# Contributing to gateway-benchmarks

Thanks for taking the time to look at this. This document describes
the **four kinds of contributions we actively want** and the process
each one follows.

## TL;DR

| You want to… | Do this |
|---|---|
| Flag a bug / regression in the framework | Open a GitHub Issue using the bug template. |
| Tune a gateway we already test | Open a PR against `gateways/<gw>/<profile>/`. Follow the [gateway-tuning PR flow](#gateway-tuning-prs) below. |
| Add support for a new gateway | Open a discussion first, then a PR once the shape is agreed. |
| Improve a doc, fix a typo, or lift a CI job | Open a PR — no discussion needed, just make sure CI is green. |

## Code of Conduct

This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
By participating you are expected to uphold it.

## Neutrality statement

The benchmark is developed by **Wallarm, Inc.** — the author of one of
the gateways under test (`wallarm` column). We explicitly invite
outside maintainers of competing gateways to propose better
configurations. If the PR (a) keeps parity attestation green, (b)
keeps the canonical values from `gateways/_reference/values.yaml`
unchanged, and (c) produces a stable ranking in two back-to-back
runs — we will merge it.

The benchmark is **not** a tool for making any particular gateway look
good; it is a tool for letting an independent reviewer reproduce the
ranking bit-for-bit and decide for themselves.

## Prerequisites

- Linux or macOS host
- Docker ≥ 24.0 (Docker Desktop or Colima on macOS; native engine on
  Linux)
- Go ≥ 1.23 (building the `bench` binary + running the test suite)
- Make, bash, jq, curl (all standard on the tested platforms)
- For local sweeps: 8+ physical cores, 16 GB RAM
- For AWS sweeps: AWS credentials with permission to provision
  `c6i.2xlarge` in your target region, `tofu` (OpenTofu) ≥ 1.7

Verify with:

```bash
make prereqs-check
```

## Repository layout

```
.
├── TASK.md                     # PRD — what the benchmark measures
├── ROADMAP.md                  # phased implementation plan
├── CHANGELOG.md                # versioned release notes
├── Makefile                    # single entry point
├── backend/                    # vendored go-httpbin upstream
├── gateways/                   # per-gateway × policy configs
│   └── _reference/             # shared parity assets (public by design)
├── fixtures/                   # parity probe fixtures (one per policy)
├── k6/                         # load profiles + scenarios
├── orchestrator/               # Go `bench` binary
├── infra/
│   ├── local/                  # Docker Compose 3-host emulation
│   └── aws/                    # OpenTofu cluster-placement-group module
├── scripts/                    # parity, load, aggregate, fetch, ...
└── docs/                       # architecture / policies / loads / reproducibility / ...
```

## Gateway-tuning PRs

This is the most common external contribution. Follow these rules or
the PR will bounce in review:

1. **One gateway per PR.** `gateways/<gw>/<profile>/` only. If the
   tuning requires a shared asset change (`gateways/<gw>/_shared/…`),
   call that out explicitly — it affects every profile for that
   gateway.
2. **Do not touch `gateways/_reference/`.** Those assets are the
   canonical values that parity attestation binds to. If a value
   genuinely needs to change (vanishingly rare), open a separate
   issue first.
3. **Run parity locally before opening the PR.**

   ```bash
   make parity-gateway PARITY_GATEWAY=<gw> PARITY_PROFILE=<profile>
   ```

   Every probe must return `PASS` (or `FEATURE-MISSING` with a
   documented justification — see `docs/GATEWAYS.md`).
4. **Run at least the baseline load profile.**

   ```bash
   make load-gateway LOAD_GATEWAY=<gw> LOAD_PROFILE=p1-baseline
   ```

   Attach the `reports/<run-id>/report.html` (or the
   `reports/<run-id>/matrix.md`) to the PR description.
5. **Justify each knob.** Every non-default directive in the diff
   needs a comment *in the config file* explaining why it's there.
   The reviewer should never have to dig through vendor docs to guess
   intent.
6. **Link upstream.** If the tuning depends on a specific gateway
   version, vendor documentation page, or issue — link it.

A worked example of the expected tone lives in
`gateways/traefik/p05-rl-endpoint/` (per-profile
`forwardedHeaders.insecure`), `gateways/kong/p02-jwt/` (sandbox
allow-list), and `gateways/nginx/p12-full-pipeline/` (phase-ordering
comment).

## Framework PRs

Non-gateway PRs (orchestrator, CI, infra, docs, scripts) follow the
standard flow:

1. `go vet ./...` — must be clean.
2. `go test -race ./...` — must pass.
3. `shellcheck --severity=warning scripts/*.sh` — must be clean.
4. CI is the source of truth; if CI is red, the PR isn't ready.

## Commit message style

We follow a loose Conventional Commits style:

```
<type>(<scope>): <short imperative subject line ≤ 72 chars>

<longer body, wrap at 72 cols, explain why rather than what>

<optional trailers>
```

`<type>` is one of `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`,
`test`. `<scope>` is typically a phase (`phase-4`, `phase-8`) or
a subsystem (`runner`, `aggregate`, `infra-aws`). See
`git log --oneline` for examples.

## Reproducibility expectations

A PR that changes anything touched by a benchmark run **must** remain
reproducible:

- The two-run playbook in
  [`docs/REPRODUCIBILITY.md § AWS canonical-run playbook`](./docs/REPRODUCIBILITY.md)
  must still exit `0 REPRODUCIBLE` or `1 SOFT DIFF` after the change.
- If the change intentionally shifts a metric (new gateway version,
  new kernel tuning, etc.), call that out in the PR description and
  bump `ROADMAP.md § Status` so the diff is visible in the next tag.

## Release process

Maintainers only — see `docs/RELEASE.md` for the mechanics. External
contributors don't need to cut tags; land your PR and we'll batch it
into the next point release.

## Questions

Open a [GitHub Discussion](https://github.com/wallarm/gateway-benchmarks/discussions).
Security issues go to [`SECURITY.md`](./SECURITY.md) — please do not
open a public issue for those.
