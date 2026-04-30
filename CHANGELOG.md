# Changelog

All notable changes to **gateway-benchmarks** are recorded here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [SemVer](https://semver.org/spec/v2.0.0.html).

For the canonical HTML report and `compare-runs` verdict that ship
alongside each tagged release, see the corresponding
[GitHub Release](https://github.com/wallarm/gateway-benchmarks/releases)
asset.

## [Unreleased]

### Added

- **Phase 5 — TLS data plane for s13 / s14 HTTPS scenarios across all
  seven gateways.** The `gateways/_reference/tls/bench.{crt,key}` chain
  (CN=bench.local, SAN: localhost / gateway / 127.0.0.1, valid until
  2126) is now wired into every column:
  - `nginx` — `listen 9443 ssl;` server block (already present).
  - `traefik` — `websecure` entryPoint + dynamic-config certificate.
  - `kong` — `KONG_PROXY_LISTEN: "..., 0.0.0.0:9443 ssl ..."`
    + `KONG_SSL_CERT*` env vars.
  - `apisix` — `apisix.ssl.enable: true` in standalone config + inline
    `ssls:` block in p01 / p12 declarative configs.
  - `envoy` — second `listener_tls` with `DownstreamTlsContext`,
    sharing the HTTP listener's filter chain via YAML anchors so the
    s13/s14-vs-s01/s12 delta isolates TLS cost only.
  - `wallarm` — `net.https_port: 9443` + `certificate_files` +
    catch-all `virtual_hosts` HTTPS entry.
  - `tyk` — TLS-terminator nginx sidecar (Tyk OSS lacks per-listener
    TLS toggles; `http_server_options.use_ssl` is global). Documented
    deviation: s13/s14 numbers for tyk reflect the `nginx-TLS + tyk`
    stack, not Tyk's own TLS implementation.
- **`FEATURE-MISSING-<scenario>` marker** in `aws-clean-cell.sh` —
  scenario-specific opt-out that doesn't pull the whole policy out of
  the matrix. Used to mark architectural gaps (was the bridge before
  the tyk sidecar landed) but kept in tree for future cases.

### Removed

- **Legacy aggregation/report shell pipeline.** Three precursor scripts
  and their Makefile entry points were removed once the Go orchestrator
  achieved parity:
  - `scripts/aggregate-csv.sh` → use `bench aggregate`
  - `scripts/aggregate-multi-csv.sh` → use `bench compare-runs`
  - `scripts/render-html-report.py` → use `bench report`
  - `make load-aggregate`, `make load-combine`, `make load-report`
  Migration: every flag previously accepted by these scripts has a
  direct equivalent on the Go subcommands; see `orchestrator/README.md`
  for the canonical CLI.

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
  `cells.jsonl + manifest.json`.
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
- **Documentation** — `TASK.md` (PRD),
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
