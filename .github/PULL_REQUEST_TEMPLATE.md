<!-- Thanks for the PR. Fill in the sections that apply and delete the rest. -->

## Summary

<!-- One paragraph. What does this PR change, and why? -->

## Change type

<!-- Tick exactly one. -->

- [ ] **Gateway tuning** — change under `gateways/<gw>/<profile>/` only
- [ ] **New gateway support** — new column in the matrix
- [ ] **Framework** — orchestrator / CI / infra / scripts
- [ ] **Docs only**
- [ ] **Other** (explain below)

---

## Gateway-tuning PRs only

<!-- Delete this section if the checkbox above is not "Gateway tuning". -->

- Gateway: `<gw>` (e.g. `traefik`)
- Profile(s) touched: `<profile1>, <profile2>` (e.g. `p05-rl-endpoint`)
- Gateway version pinned at: `<image:tag@sha256:...>`

### Parity

```text
<paste the tail of `make parity-gateway PARITY_GATEWAY=<gw> PARITY_PROFILE=<profile>`>
```

Every probe is `PASS` (or documented `FEATURE-MISSING` in
`docs/GATEWAYS.md`): **yes / no + link to the deviation row**

### Load baseline

```text
<paste the tail of `make load-gateway LOAD_GATEWAY=<gw> LOAD_PROFILE=p1-baseline`
 or attach reports/<run-id>/matrix.md>
```

### Justification for each non-default knob

<!-- One bullet per non-default directive in the diff. -->
- `<config key> = <value>` — <why, link to vendor doc / upstream issue>

### Upstream references

<!-- Vendor doc, GitHub issue, or PR number for each non-obvious decision. -->

---

## Framework PRs only

<!-- Delete this section if the change is gateway-only. -->

- [ ] `go vet ./...` clean
- [ ] `go test -race ./...` pass
- [ ] `shellcheck --severity=warning scripts/*.sh` clean
- [ ] Docs updated where behaviour / flags / outputs changed
- [ ] CHANGELOG.md entry under `[Unreleased]`

### Reproducibility impact

<!-- Does this change ANY cell metric, or alter the manifest shape? -->
- [ ] No metric impact
- [ ] Metric impact, justified in the description below
- [ ] Manifest shape changed — bumped `orchestrator/internal/manifest` version

---

## Screenshots / output snippets

<!-- Optional — helpful for visible changes (HTML report, CLI output). -->

## Related

<!-- Issues, discussions, prior PRs, upstream bugs. -->
