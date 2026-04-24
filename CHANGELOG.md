# Changelog

All notable changes to **gateway-benchmarks** are recorded here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [SemVer](https://semver.org/spec/v2.0.0.html).

For the canonical HTML report and `compare-runs` verdict that ship
alongside each tagged release, see the corresponding
[GitHub Release](https://github.com/wallarm/gateway-benchmarks/releases)
asset.

## [Unreleased]

Nothing yet — the next tag is `v0.1.1` or `v0.2.0` depending on the
scope of changes merged after `v0.1.0`.

## [0.1.0] — TBD (first public release)

> **Phase 9 deliverable.** Cuts the first reproducible AWS canonical
> run and attaches the `report.html` + `compare-runs` verdict as
> release assets.

The first public release of the benchmark framework. Everything below
has been delivered through Phases 1 – 8 and the post-Phase-8 tech-debt
sweep; Phase 9 is the release cut itself.

### Added

- **Benchmark matrix** — 7 gateways (NGINX, Envoy, Wallarm, Traefik,
  Kong, APISIX, Tyk) × 12 policy profiles × 4 load profiles × 11 HTTP
  scenarios; plus the supplemental `p03-jwks-rs256-basic` capability
  track (parity-only, off-grid).
- **Parity attestation** — every cell verifies that the gateway treats
  the canonical probe identically before any load is generated;
  deviations are marked and excluded from the aggregate ranking.
- **Deterministic manifest** — `reports/<run-id>/manifest.json`
  pins the repo SHA, RNG seed, k6 binary digest, per-gateway image
  digests, host info, and the selected rows.
- **`bench` Go orchestrator** — single binary drives
  `parity → load → aggregate → manifest → report`, with an atomic
  append-only checkpoint (resumable mid-sweep), a watchdog that tags
  cells `CRASHED` on gateway container exit, configurable retry on
  crash (`--retry-on-crash`), and a native Docker-Engine stats
  collector (replaces the shell sidecar).
- **`bench report`** — self-contained HTML report (embedded CSS/JS
  + Chart.js CDN bundle) rendered straight from
  `cells.jsonl + manifest.json`; the Python prototype
  `scripts/render-html-report.py` is deprecated.
- **`bench compare-runs`** — reproducibility gate between any two
  run-ids. Checks identity (git SHA, seed, k6 digest, per-gateway
  image digests, selected rows), per-cell metric tolerance
  (RPS ± 3 %, p50/p95/p99 ± 10 %, memory ± 5 %, CPU ± 10 %, exact
  match on 5xx + 4xx-expected), and top-3 rank stability per
  `(policy, load, scenario)` column. Exits
  `0 REPRODUCIBLE · 1 SOFT DIFF · 2 NOT REPRODUCIBLE`.
- **Infrastructure** — local Docker Compose 3-host stack
  (loadgen ↔ gateway ↔ backend on two isolated bridge networks) plus
  an AWS OpenTofu module (3 × `c6i.2xlarge` in a single cluster
  placement group, isolated subnets, SG + userdata bootstrap).
- **Vendored backend** — `mccutchen/go-httpbin@v2.22.1` pinned into
  `backend/upstream/httpbin/`; static single-image build for
  reproducible upstream behaviour.
- **Documentation** — `TASK.md` (PRD), `ROADMAP.md`,
  `docs/ARCHITECTURE.md`, `docs/POLICIES.md`, `docs/LOAD-PROFILES.md`,
  `docs/GATEWAYS.md` (including a one-row-per-cell deviations rollup),
  `docs/REPORT.md`, `docs/REPRODUCIBILITY.md` (manifest schema, CLI
  reference, tolerance table, AWS canonical-run playbook),
  `orchestrator/README.md`.
- **Bandwidth metrics** — `net_rx_total_bytes`, `net_tx_total_bytes`,
  `net_rx_peak_bps`, `net_tx_peak_bps` appended to the canonical
  `matrix.csv` (31 columns = 27 legacy + 4 bandwidth).
- **Lint CI** — `shellcheck` (severity=warning), `go vet`, `go test`,
  and a markdown link-checker run on every push + PR.

### Changed

- **Policy matrix renumbering** — inserted the supplemental
  `p03-jwks-rs256-basic` profile as `p03`; shifted the historical
  `p03..p11` to `p04..p12`. Every per-gateway config, fixture, doc,
  and script updated in lock-step (see commit `1065d75`).
- **Reports directory** — `reports/` is no longer tracked; external
  storage is supported via a local symlink (see `docs/REPORT.md`).
- **CI actions bumped** — `actions/checkout@v4 → v5`,
  `actions/setup-go@v5 → v6`; clears the Node 20 runtime
  deprecation warning.

### Security

- Reference JWT / JWKS / TLS material under `gateways/_reference/` is
  **intentionally public** (`bench.local` self-signed cert,
  `bench-jwt-hs256-secret-2026`, `bench-rs256-2026` RSA key). No
  production system trusts any of these values. See
  `gateways/_reference/README.md` and
  `gateways/_reference/jwks-rs256/README.md` for the canonical
  disclaimer.

### Neutrality

Wallarm, Inc. develops and maintains this repository. The author of one
of the gateways under test is a maintainer; conflict of interest is
neutralised by (a) freezing every config + scenario at release tag,
(b) running parity attestation before every cell, (c) accepting
reasonable external tuning of a competing gateway as a PR
(see `CONTRIBUTING.md`), and (d) logging every deviation in
`docs/GATEWAYS.md` with a reason and an upstream reference.

[Unreleased]: https://github.com/wallarm/gateway-benchmarks/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/wallarm/gateway-benchmarks/releases/tag/v0.1.0
