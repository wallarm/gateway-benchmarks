# Canonical-run handoff (Phase 9)

> Executable handoff for the first `v0.1.0` canonical sweep on AWS.
> Read top-to-bottom; tick each checkbox as you go. Total wall-clock
> ≈ 8 h, active operator time ≈ 90 min.

This document is the **minimum script** to produce the two
independent canonical runs that `v0.1.0` attaches as Release assets.
It is a simplified, annotated view of
[`docs/REPRODUCIBILITY.md § AWS canonical-run playbook`](./REPRODUCIBILITY.md) and
[`docs/RELEASE.md`](./RELEASE.md); use it when you actually sit down
to cut the tag.

## Pre-flight (≈ 10 min)

- [ ] On `main`, working tree clean, in sync with `origin/main`
- [ ] CI on the tip commit is green (shellcheck / go-vet / go-test /
      markdown)
- [ ] AWS credentials exported in the current shell
      (`aws sts get-caller-identity` prints your account)
- [ ] SSH keypair that Terraform can reference is already in AWS
      (`aws ec2 describe-key-pairs --key-names <name>` returns it)
- [ ] `infra/aws/terraform.tfvars` exists and sets at minimum:
      `aws_region`, `availability_zone`, `ssh_key_name`,
      `allowed_ssh_cidrs`
- [ ] `tofu version` reports ≥ 1.7
- [ ] `go version` reports ≥ 1.23
- [ ] Local disk has ≥ 5 GB free under `reports/` (or a symlink to
      external storage — see [`docs/REPORT.md`](./REPORT.md))
- [ ] Budget approval for ≈ \$15 of AWS spend

## Step 1 — Provision the cluster (≈ 5 min)

```bash
# Build the orchestrator with the release version stamped in so the
# manifest carries "v0.1.0" instead of "dev":
make bench-build ORCH_VERSION=v0.1.0

make perf-aws-init        # tofu init (idempotent)
make perf-aws-deploy      # tofu apply + userdata bootstrap (≈ 3 min)
```

Verification:

- [ ] `make perf-aws-status` prints three reachable IPs and one
      cluster placement group
- [ ] `ssh ubuntu@<loadgen>` succeeds (userdata seeded the keys
      during bootstrap)
- [ ] From loadgen: `curl --connect-timeout 2 http://<gateway>:9080/status/200`
      returns `200` (NGINX is the default test image on the gateway
      host right after deploy)

## Step 2 — First canonical run (≈ 3.5 h)

```bash
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-a \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run A — 3×c6i.2xlarge, cluster PG, seed=42"
```

While this runs:

- Tail the checkpoint: `tail -f reports/v0.1.0-aws-a/checkpoint.jsonl`
- Each cell takes ≈ 2 – 4 min (p1-baseline) or ≈ 10 min (p2-sustained
  at 100 VU × 5 min). The orchestrator auto-retries `CRASHED` cells
  once (`--retry-on-crash 1`).

Verification at the end:

- [ ] `reports/v0.1.0-aws-a/manifest.json` exists, non-empty, carries
      `git_sha`, `seed=42`, 7 gateway image digests
- [ ] `reports/v0.1.0-aws-a/matrix.csv` has `≥ 336` rows
      (7 gw × 12 policies × 4 loads = 336 — the exact count depends
      on which scenarios are selected by default)
- [ ] `reports/v0.1.0-aws-a/report.html` renders (open it locally to
      double-check)
- [ ] Checkpoint shows **0 `TIMEOUT`** verdicts; ≤ **1 % `CRASHED`**
      after retry (higher: investigate before run B)

## Step 3 — Second canonical run (≈ 3.5 h)

```bash
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-b \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run B — reproducibility witness"
```

Same verification as step 2, but for run B.

## Step 4 — THE GATE (≈ 30 s)

```bash
make bench-compare-runs \
    BENCH_COMPARE_A=v0.1.0-aws-a \
    BENCH_COMPARE_B=v0.1.0-aws-b
echo "gate exit = $?"
```

Expected outcomes:

| Exit | Meaning | What to do |
|---|---|---|
| **0** | REPRODUCIBLE — every tolerance + rank check clean | proceed to step 5 |
| **1** | SOFT DIFF — one or more metrics outside tolerance but top-3 rank stable | **document in release notes**, then proceed (this is the explicit design contract — see `docs/REPRODUCIBILITY.md § Tolerances`) |
| **2** | NOT REPRODUCIBLE — top-3 rank flipped | **abort the release**, re-run one of the two sweeps, investigate before re-gating |

Capture the full gate output to a file:

```bash
mkdir -p reports/compare
/path/to/bench compare-runs v0.1.0-aws-a v0.1.0-aws-b \
    > reports/compare/v0.1.0-aws-a__vs__v0.1.0-aws-b.txt
```

This file is a Release asset in step 7.

## Step 5 — Final report render (≈ 10 s)

```bash
make perf-aws-report BENCH_RUN_ID=v0.1.0-aws-a
```

This regenerates `reports/v0.1.0-aws-a/report.html` with the latest
render pass. Open it locally and eyeball:

- [ ] Hero cards render with ≥ 6 green gateway columns
- [ ] Every `(policy, load, scenario)` cell is clickable
- [ ] Drill-downs show p50/p95/p99, CPU, mem, bandwidth, 2xx / 4xx /
      5xx breakdown
- [ ] No `NaN` / `undefined` / `ZgotmplZ` leaks anywhere in the DOM

## Step 6 — Tear down the cluster

```bash
make perf-aws-destroy
```

Verification:

- [ ] `aws ec2 describe-instances` in your region shows the three
      bench instances as `terminated`
- [ ] `aws ec2 describe-security-groups` no longer lists the bench
      SGs

## Step 7 — Cut the tag + Release

Follow `docs/RELEASE.md § 3 – 5`. The Release assets are, in order:

1. `reports/v0.1.0-aws-a/report.html` (the canonical HTML report)
2. `reports/v0.1.0-aws-a/manifest.json` (proves reproducibility)
3. `reports/v0.1.0-aws-a/matrix.csv` (31-column wide CSV)
4. `reports/v0.1.0-aws-a/cells.jsonl` (JSONL superset with
   `health` + `timing_broken`)
5. `reports/compare/v0.1.0-aws-a__vs__v0.1.0-aws-b.txt` (gate verdict)

## Step 8 — Announcement

Paste the announcement snippet from `docs/release-notes/v0.1.0.md §
Announcement snippet` into GitHub Discussions + the README preamble
(see the `<!-- v0.1.0 ANNOUNCEMENT -->` anchor in `README.md`).

---

## If something goes wrong

| Symptom | First thing to check |
|---|---|
| `perf-aws-deploy` hangs on "waiting for SSH" | Security group allows your office IP (`allowed_ssh_cidrs` in `terraform.tfvars`). |
| Many cells flip to `CRASHED` on run A | Gateway image is mismatched for your region. Check `docker inspect` on the gateway host; the orchestrator prints which container died. |
| `bench compare-runs` exits `2` | Inspect `reports/compare/...txt`, find the diverging `(policy, load, scenario)` columns, cross-reference with `docs/GATEWAYS.md` — usually a known-flaky cell needs to be marked `EXCLUDED` before the next canonical. |
| `report.html` shows `NaN` on a metric card | One cell's `k6-summary.json` is malformed. `rm -rf reports/<run-id>/raw/<gw>/<cell>` and `make bench-aggregate BENCH_RUN_ID=<run-id>` to drop it and regenerate. |
| Bill shock | Check you ran `make perf-aws-destroy`. AWS bills per-second for `c6i.2xlarge`; a forgotten cluster is ≈ \$1.2/h. |

## Contact

Framework questions → GitHub Issues. Canonical-run specifics → file
an Issue with the `canonical-run` label and attach the full
checkpoint + compare-runs output.
