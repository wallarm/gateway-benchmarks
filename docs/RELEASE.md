# Release process

> Maintainer-only. External contributors land PRs; we batch them into
> the next tag.

This document is the authoritative procedure for cutting a tagged
release. It is the **single source of truth for the `v0.1.0`
ceremony**; later releases reuse the same script with a different
version string.

## 0. Prerequisites

- Clean working tree on `main`, up to date with `origin/main`
- CI green on the tip commit (lint, go vet, go test, shellcheck,
  markdown link-check)
- AWS credentials with permission to provision `c6i.2xlarge` in the
  target region + SSH keypair
- OpenTofu ≥ 1.7 installed locally (`tofu version`)
- A **budget** for the run. A full canonical sweep costs
  approximately **\$15 on AWS** (3 × `c6i.2xlarge` for ≈ 7 h wall-
  clock + minimal data egress).

## 1. Tag readiness checklist

Walk through these before touching `git tag`:

- [ ] `CHANGELOG.md` has a concrete `[X.Y.Z] — YYYY-MM-DD` header (no
      `TBD`) with every change since the previous tag, grouped under
      `Added / Changed / Fixed / Removed / Security` sub-headers.
- [ ] `README.md` status badge reflects the tag being cut.
- [ ] `docs/REPRODUCIBILITY.md § Status` matches the new tag's phase
      state.
- [ ] No `TODO(vX.Y.Z)` markers remain for this version.
- [ ] `scripts/prereqs-check.sh` passes on a freshly cloned checkout
      (no implicit local-state dependency).

## 2. AWS canonical-run (tag-blocking)

This is step 4 of [`docs/REPRODUCIBILITY.md § AWS canonical-run
playbook`](./REPRODUCIBILITY.md). The tag **cannot** ship until
`bench compare-runs` exits `0` (REPRODUCIBLE) or `1` (SOFT DIFF).
Exit `2` means the framework is not reproducible on this commit and
the release must be aborted.

```bash
# 0. Stamp the release version into the orchestrator binary so the
#    manifest carries "v0.1.0" instead of "dev":
make bench-build ORCH_VERSION=v0.1.0

# 1. Bring up the 3-EC2 cluster placement group:
make perf-aws-init
make perf-aws-deploy

# 2. First canonical run:
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-a \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run A — 3×c6i.2xlarge, cluster PG, seed=42"

# 3. Second independent run — same everything else:
make perf-aws-run \
    BENCH_RUN_ID=v0.1.0-aws-b \
    BENCH_REPS=2 \
    BENCH_SEED=42 \
    BENCH_NOTES="v0.1.0 canonical run B — reproducibility witness"

# 4. THE GATE — must exit 0 or 1:
make bench-compare-runs \
    BENCH_COMPARE_A=v0.1.0-aws-a \
    BENCH_COMPARE_B=v0.1.0-aws-b
echo "gate exit = $?"

# 5. Render the canonical HTML from run A:
make perf-aws-report BENCH_RUN_ID=v0.1.0-aws-a

# 6. Tear down:
make perf-aws-destroy
```

Capture:
- `reports/v0.1.0-aws-a/report.html`
- `reports/v0.1.0-aws-a/manifest.json`
- `reports/v0.1.0-aws-a/matrix.csv`
- `reports/v0.1.0-aws-a/cells.jsonl`
- `reports/compare/v0.1.0-aws-a__vs__v0.1.0-aws-b.txt` (gate output)

These are the release assets in step 4 below.

## 3. Cut the tag

```bash
# Annotated tag with the CHANGELOG entry in the message body:
git tag -a v0.1.0 -m "$(cat <<'EOF'
v0.1.0 — first public release

First reproducible AWS canonical run of the 7-gateway × 12-policy ×
4-load × 11-scenario benchmark. See CHANGELOG.md for the full change
list.

Canonical run: v0.1.0-aws-a
Reproducibility witness: v0.1.0-aws-b
Gate: REPRODUCIBLE (exit=0)     # or SOFT DIFF (exit=1) — quote the actual outcome
EOF
)"

git push origin v0.1.0
```

## 4. GitHub Release

```bash
gh release create v0.1.0 \
    --title "v0.1.0 — first public release" \
    --notes-file docs/release-notes/v0.1.0.md \
    reports/v0.1.0-aws-a/report.html \
    reports/v0.1.0-aws-a/manifest.json \
    reports/v0.1.0-aws-a/matrix.csv \
    reports/v0.1.0-aws-a/cells.jsonl \
    reports/compare/v0.1.0-aws-a__vs__v0.1.0-aws-b.txt
```

The release notes body is a shortened version of the `CHANGELOG.md`
entry plus a link to the reproducibility gate verdict. Keep it under
400 words — everything longer belongs in the CHANGELOG.

## 5. Post-release

- [ ] Open `[Unreleased]` section in `CHANGELOG.md`.
- [ ] Bump the README status badge for the next milestone if needed.
- [ ] Announce on the discussions tab — the README announcement
      template is `docs/release-notes/v0.1.0.md § Announcement
      snippet`.
- [ ] File the follow-up issues captured by the canonical run (known
      flakes, performance-regressions worth a closer look, etc.).

## Post-mortem template (for `v0.1.x` patches)

If the canonical run uncovers a framework regression that needs a
point release, file it using this template:

```markdown
### What broke
### Blast radius
### Root cause
### Fix
### Reproducibility impact
### Follow-ups
```

---

## Why a whole document for this

The first public release is the only place where a downstream
reviewer forms their "is this benchmark credible" opinion. Ambiguity
in the release ceremony is the single biggest cost multiplier on that
opinion — hence the checklist.
