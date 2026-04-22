# orchestrator — Go Binary

Orchestrator that drives every cell of the matrix (policy × protocol × load profile × gateway) in a single run.

## Responsibilities

1. **Load the run config** — `run.yaml` (which cells, how many repetitions, timeouts).
2. **Produce the manifest** — image digests, git SHA of this repo, RNG seed, timestamps, host info.
3. **Bring up the environment** — docker compose (local) or Terraform + SSH deployment (AWS).
4. **Parity attestation** — run `scripts/parity-attestation.sh` before every cell.
5. **Launch k6** with the requested profile and scenario.
6. **Collect metrics** — k6 summary, `docker stats` peak and steady-state, bandwidth.
7. **Classify errors** — 5XX, 4XX-expected, client-side (k6), excluded (handshake).
8. **Watchdog** — restart the gateway on a crash, tag the cell as CRASHED.
9. **Checkpoints** — persist progress so an interrupted run can resume.
10. **Kick off the report generator** at the end.

## Commands

```bash
make orchestrator-build      # compile to orchestrator/bin/bench
bench run --mode local       # full cycle locally
bench run --mode aws         # full cycle on 3 EC2 in a placement group
bench manifest print         # print the manifest of the latest run
bench parity check           # run parity attestation only
```

## Stack

- Go 1.23+ (minimum; pinned in `go.mod`)
- Minimal dependencies: `spf13/cobra`, `go-yaml/yaml`, `docker/docker/client`.
- No frameworks — a single ~15 MB binary.

## Status

> Phase 6 in the roadmap — pending. This directory is currently a stub.
