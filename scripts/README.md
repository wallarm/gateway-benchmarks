# scripts — Helper Scripts

Utility scripts called by the `Makefile` or the orchestrator.

## Planned scripts

| File | Purpose |
|------|---------|
| `check-prereqs.sh`         | Verify Docker ≥ 24, k6, jq, go, tofu for `local`/`aws` modes |
| `parity-attestation.sh`    | Verify that every gateway handles a policy identically (HMAC seed, rate-limit windows, body-rewrite diff) |
| `generate-report.go`       | Build the HTML report from `reports/<run>/raw/` — likely part of the orchestrator but allowed as a standalone tool |
| `ssh-deploy.sh`            | Deploy the docker-compose stack to 3 EC2 hosts (`aws` mode) |
| `fetch-reports.sh`         | Pull raw data from EC2 back into `reports/<run>/` |

## Conventions

- Every script must pass `shellcheck --severity=style` (see `.github/workflows/lint.yml`)
- macOS + Linux compatibility: **do not use** `grep -P`, `sed -i` without `''`, or `readlink -f` — use portable equivalents instead
- Exit codes: 0 — OK, 1 — usage error, 2 — prerequisite missing, 3 — runtime failure

## Status

> Stub. Populated alongside Phases 3, 5, and 6.
