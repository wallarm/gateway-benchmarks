# reports — Output Directory

The orchestrator deposits run artefacts here. Every run is its own folder.

## Per-run layout

```
reports/<timestamp>_<git-sha>/
├── manifest.json              # TASK §7: digests, seeds, host info, timestamps
├── report.html                # the main report (visual style — see docs/REPORT.md)
├── summary.csv                # wide table: gateway × (profile, scenario) × metric
├── summary.json               # same data, JSON
├── parity/
│   ├── p01-bypass.json        # attestation result
│   └── ...
└── raw/
    ├── wallarm/
    │   ├── p1-baseline__s01-bypass-http/
    │   │   ├── k6-summary.json
    │   │   ├── k6-stream.json.gz
    │   │   ├── docker-stats.json
    │   │   └── logs/
    │   └── ...
    ├── nginx/
    └── ...
```

## Report reference

Visual style and layout follow [docs/REPORT.md](../docs/REPORT.md). The actual reference artefact is produced in Phase 7 and shipped as part of that phase's deliverable.

Section structure per PRD (TASK §6):

- Hero with the ranking and Wallarm's neutrality disclaimer
- Executive summary
- Run parameters (links to manifest)
- Summary table (7 gateways × ≈96 metrics)
- Scrollable tabs per policy and load profile
- Bandwidth / RSS peak-and-steady / error breakdown (4 columns)

## Git

`reports/` **is tracked** — CI publishes fresh reports on each release. Raw data above 50 MB is pushed to Git LFS (see `.gitattributes`).

## Status

> Phase 7 in the roadmap — pending.
