#!/usr/bin/env python3
"""
DEPRECATED — superseded by `bench report` (orchestrator/cmd/report.go).

The Phase-7 Go orchestrator now renders the canonical HTML report
directly from `cells.jsonl` + `manifest.json`:

    make orchestrator-build
    bench report --run-id <run-id>
    bench report --combined run-a,run-b,run-c

Use the Go binary for every new report — it consumes the typed
`cells.jsonl` produced by `bench run` / `bench aggregate`, has the
same hero / executive-summary / memory-grid / radar / per-policy
layout, and emits a self-contained HTML page (no Python toolchain
required).

This Python script is kept in-tree for one cycle so historical
reports built off legacy CSVs (pre-`cells.jsonl` runs in
`reports/combined-pathA-*`) remain re-renderable, but no new
features or fixes will land here. Do not extend it.

──────────────────────────────────────────────────────────────────
Render a Chart.js-driven HTML benchmark report from a combined matrix CSV
produced by `scripts/aggregate-multi-csv.sh`.

Layout mirrors the reference Wallarm benchmark report:
    Hero  →  Executive Summary  →  Memory Footprint
          →  Overall Profile (radar)  →  Per-policy tabs

Each per-policy tab carries:
    - winner banner
    - horizontal bar chart (RPS)
    - horizontal bar chart (p50 vs p95 latency)
    - detail table (gateway / RPS / p50 / p95 / max / total reqs / errors /
                    overhead vs winner)

Usage:
    python3 scripts/render-html-report.py \\
        --input reports/combined-pathA-p1-baseline/matrix.csv \\
        --output reports/combined-pathA-p1-baseline/report.html \\
        --title "API Gateway Benchmark — Path A" \\
        --env   "Apple Silicon Docker Desktop · k6 · p1-baseline (10 VUs × 60s closed-loop)"

The script has zero third-party dependencies — it only uses the standard
library + inline Chart.js@4 (CDN) in the emitted HTML.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import html
import json
import pathlib
import re
import sys
from collections import defaultdict


# ---- Gateway catalog --------------------------------------------------------

# Matches the brand palette from the reference report (one consistent colour
# per gateway so the multi-panel charts cross-reference visually).
GATEWAY_COLORS = {
    "nginx":   "#009639",
    "envoy":   "#AC6EF5",
    "traefik": "#24A1C1",
    "kong":    "#003459",
    "apisix":  "#E8433E",
    "tyk":     "#1A1A2E",
    "wallarm": "#FF6B35",
    "backend": "#339AF0",
}

# Stack / version metadata — sourced from gateways/<gw>/docker-compose.yaml
# image pins at the time of the run. Update in lock-step when image pins
# refresh.
GATEWAY_STACK = {
    "nginx":   ("C",        "1.27.3-alpine"),
    "envoy":   ("C++",      "v1.32.6 distroless"),
    "traefik": ("Go",       "v3.3.4"),
    "kong":    ("Lua",      "3.9.1 (OpenResty)"),
    "apisix":  ("Lua",      "3.15.0-debian"),
    "tyk":     ("Go",       "v5.11.1 CE"),
    "wallarm": ("Rust/C",   "main-5f1ab30 (source build)"),
}

# Stable ordering for tabs — canonical p01..p12 sequence.
POLICY_ORDER = [
    "p01-vanilla",
    "p02-jwt",
    "p03-jwks-rs256-basic",
    "p04-rl-static",
    "p05-rl-endpoint",
    "p06-rl-dynamic-low",
    "p07-rl-dynamic-high",
    "p08-req-headers",
    "p09-resp-headers",
    "p10-req-body",
    "p11-resp-body",
    "p12-full-pipeline",
]

# Short labels for tab buttons (the `pNN-` prefix is redundant on the UI
# because the tab order is deterministic).
POLICY_LABEL = {
    "p01-vanilla":          "p01 · vanilla",
    "p02-jwt":              "p02 · jwt HS256",
    "p03-jwks-rs256-basic": "p03 · jwks RS256",
    "p04-rl-static":        "p04 · rl-static",
    "p05-rl-endpoint":      "p05 · rl-endpoint",
    "p06-rl-dynamic-low":   "p06 · rl-dyn-low",
    "p07-rl-dynamic-high":  "p07 · rl-dyn-high",
    "p08-req-headers":      "p08 · req-headers",
    "p09-resp-headers":     "p09 · resp-headers",
    "p10-req-body":         "p10 · req-body",
    "p11-resp-body":        "p11 · resp-body",
    "p12-full-pipeline":    "p12 · full-pipe",
}


# ---- CSV parsing ------------------------------------------------------------

def _num(value: str) -> float:
    """Tolerant float parser — empty / non-numeric → 0.0."""
    if value is None or value == "":
        return 0.0
    try:
        return float(value)
    except ValueError:
        return 0.0


def load_matrix(path: pathlib.Path) -> list[dict]:
    """Read the aggregated CSV into a list of dicts, preserving types we need."""
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        raise SystemExit(f"empty CSV: {path}")

    parsed = []
    for r in rows:
        # Canonical error rate: `policy_4xx_unexpected` + `policy_5xx_unexpected`
        # divided by total observations. The scenarios classify every response
        # into one of four buckets (see `k6/lib/metrics.js § errorRates`), so
        # the canonical denominator is the sum — NOT http_reqs, since requests
        # that completed their TCP round-trip but were classified by
        # `categorize_response()` as unexpected status belong in the error
        # column too. `policy_4xx_expected` is the 429 bucket on rl-* policies
        # and MUST NOT count as an error.
        ok_2xx      = _num(r.get("policy_2xx"))
        ok_4xx_exp  = _num(r.get("policy_4xx_expected"))
        bad_4xx     = _num(r.get("policy_4xx_unexpected"))
        bad_5xx     = _num(r.get("policy_5xx_unexpected"))
        total_cls   = ok_2xx + ok_4xx_exp + bad_4xx + bad_5xx

        if total_cls > 0:
            err_rate = (bad_4xx + bad_5xx) / total_cls
        else:
            err_rate = 0.0

        p50 = _num(r["http_req_duration_p50"])
        p95 = _num(r["http_req_duration_p95"])
        p99 = _num(r["http_req_duration_p99"])
        mx  = _num(r["http_req_duration_max"])

        # Instrumentation-failed sentinel: k6 reports every `http_req_duration`
        # field as 0 for tyk on this harness — 1.9M requests in 60 s cannot
        # have min/avg/max all equal to zero, so the timing histogram is
        # corrupted (tyk's response stream seems to bypass the k6 timer, a
        # known edge-case when the gateway sends Connection-reuse hints that
        # confuse k6's HTTP/1.1 timer — reproduces independently of the
        # harness). We trust `http_reqs` (counter-only) but NOT the duration
        # quantiles in this state. See README § "Known measurement gaps".
        timing_broken = (p50 == 0 and p95 == 0 and p99 == 0 and mx == 0)

        parsed.append({
            "gateway":  r["gateway"].strip('"'),
            "policy":   r["policy"].strip('"'),
            "scenario": r["scenario"].strip('"'),
            "load":     r["load"].strip('"'),
            "run_id":   r["run_id"].strip('"'),
            "verdict":  r["verdict"].strip('"'),
            "parity":   r["parity_status"].strip('"'),
            "rps":      _num(r["http_req_rate"]),
            "reqs":     int(_num(r["http_reqs"])),
            "p50":      p50,
            "p90":      _num(r["http_req_duration_p90"]),
            "p95":      p95,
            "p99":      p99,
            "max":      mx,
            "timing_broken": timing_broken,
            "err_rate": err_rate,
            "ok_2xx":   int(ok_2xx),
            "ok_429":   int(ok_4xx_exp),
            "bad_4xx":  int(bad_4xx),
            "bad_5xx":  int(bad_5xx),
            "rss_peak": _num(r["mem_rss_peak"]),   # bytes
            "rss_steady": _num(r["mem_rss_steady"]),
            "cpu_peak": _num(r["cpu_pct_peak"]),
            "cpu_steady": _num(r["cpu_pct_steady"]),
        })
    return parsed


# ---- Aggregates -------------------------------------------------------------

def build_index(rows: list[dict]) -> dict[str, dict[str, dict]]:
    """{policy: {gateway: row}} lookup, PASS cells only."""
    idx: dict[str, dict[str, dict]] = defaultdict(dict)
    for row in rows:
        if row["verdict"] == "PASS":
            idx[row["policy"]][row["gateway"]] = row
    return idx


def compute_summary(index: dict) -> list[dict]:
    """Executive-summary rows, one per gateway — avg RPS, avg err, coverage."""
    gateways = sorted({gw for pol in index.values() for gw in pol})
    summary = []
    for gw in gateways:
        cells = []
        for policy in POLICY_ORDER:
            row = index.get(policy, {}).get(gw)
            if row:
                cells.append(row)
        if not cells:
            continue
        avg_rps = sum(c["rps"] for c in cells) / len(cells)
        max_err = max(c["err_rate"] for c in cells)
        peak_rss_mb = max(c["rss_peak"] for c in cells) / (1024 * 1024)
        summary.append({
            "gateway":  gw,
            "avg_rps":  avg_rps,
            "max_err":  max_err * 100,  # %
            "coverage": f"{len(cells)}/{len(POLICY_ORDER)}",
            "peak_rss": peak_rss_mb,
            "stack":    GATEWAY_STACK.get(gw, ("?", "?")),
        })
    summary.sort(key=lambda r: r["avg_rps"], reverse=True)
    return summary


def compute_radar(index: dict) -> tuple[list[str], list[dict]]:
    """Relative RPS matrix (gateway × policy), normalised to 100% of winner."""
    gateways = sorted({gw for pol in index.values() for gw in pol})
    datasets = []
    for gw in gateways:
        data = []
        for policy in POLICY_ORDER:
            cells = index.get(policy, {})
            if not cells:
                data.append(0)
                continue
            best = max((c["rps"] for c in cells.values()), default=0)
            row = cells.get(gw)
            if not row or best <= 0:
                data.append(0)
            else:
                data.append(round(100 * row["rps"] / best, 1))
        datasets.append({
            "label":            gw,
            "data":             data,
            "borderColor":      GATEWAY_COLORS.get(gw, "#888"),
            "backgroundColor":  GATEWAY_COLORS.get(gw, "#888") + "20",
            "pointBackgroundColor": GATEWAY_COLORS.get(gw, "#888"),
        })
    labels = [POLICY_LABEL[p] for p in POLICY_ORDER]
    return labels, datasets


def compute_chart_data(index: dict) -> dict:
    """Per-policy {labels, rps, p50, p95, colors} for the bar charts.

    Latency bars are zeroed out (with null-style gap) for cells whose timing
    instrumentation returned all-zeros — otherwise a broken 0-ms reading would
    draw as a "perfect winner" and mislead the reader. RPS bars are kept
    intact because the request counter is independent of the duration
    histogram.
    """
    chart = {}
    for policy in POLICY_ORDER:
        cells = index.get(policy, {})
        if not cells:
            chart[policy] = None
            continue
        sorted_cells = sorted(cells.values(), key=lambda c: c["rps"], reverse=True)
        chart[policy] = {
            "labels":  [c["gateway"] for c in sorted_cells],
            "rps":     [round(c["rps"], 1)     for c in sorted_cells],
            # Emit `null` (JSON) for broken-timing cells so Chart.js renders
            # a visible gap rather than a spurious 0-ms winner bar.
            "p50":     [(None if c["timing_broken"] else round(c["p50"], 3)) for c in sorted_cells],
            "p95":     [(None if c["timing_broken"] else round(c["p95"], 3)) for c in sorted_cells],
            "broken":  [c["timing_broken"]     for c in sorted_cells],
            "colors":  [GATEWAY_COLORS.get(c["gateway"], "#888") for c in sorted_cells],
        }
    return chart


# ---- HTML rendering ---------------------------------------------------------

CSS = r"""
:root {
  --bg: #f5f6f8;
  --card: #ffffff;
  --dark: #1a1b2e;
  --text: #212529;
  --muted: #6c757d;
  --border: #e2e5ea;
  --mono: 'SF Mono', 'Fira Code', 'Cascadia Code', 'JetBrains Mono', monospace;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Inter, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
.wrap { max-width: 1280px; margin: 0 auto; padding: 0 1.5rem 3rem; }

.hero { background: var(--dark); color: #fff; padding: 2.5rem 0 2rem; margin-bottom: 2rem; }
.hero .wrap { display: flex; justify-content: space-between; align-items: flex-end; flex-wrap: wrap; gap: 1rem; }
.hero h1 { font-size: 1.75rem; font-weight: 700; letter-spacing: -0.02em; }
.hero .meta { font-size: 0.85rem; color: #9ca3af; }

.card { background: var(--card); border-radius: 10px; padding: 1.5rem; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }
.section-title { font-size: 1.25rem; font-weight: 700; margin: 2.5rem 0 1rem; padding-bottom: 0.4rem; border-bottom: 2px solid var(--border); }

.badge { display: inline-block; padding: 0.15rem 0.55rem; border-radius: 4px; font-size: 0.78rem; font-weight: 700; color: #fff; white-space: nowrap; letter-spacing: 0.02em; }

.ranking-table { width: 100%; border-collapse: collapse; }
.ranking-table th { text-align: left; padding: 0.6rem 0.75rem; font-size: 0.75rem; text-transform: uppercase; color: var(--muted); border-bottom: 2px solid var(--border); letter-spacing: 0.05em; }
.ranking-table td { padding: 0.6rem 0.75rem; border-bottom: 1px solid #f0f1f3; font-size: 0.9rem; }
.ranking-table tr:hover { background: #f8f9fb; }
.rank-cell { font-size: 1.3rem; text-align: center; width: 3rem; }
.num { text-align: right; font-family: var(--mono); font-size: 0.85rem; }
.meta-cell { color: var(--muted); font-size: 0.82rem; }
.error-cell { color: #dc2626; font-weight: 600; }
.winner-tag { display: inline-block; border: 2px solid; border-radius: 6px; padding: 0.25rem 0.75rem; font-size: 0.85rem; margin-left: 1rem; }
.winner-row { background: #f0fdf4; }
.excluded-row { background: #fafafa; color: var(--muted); }
.excluded-cell { font-style: italic; }

.mem-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 0.75rem; margin-top: 1rem; }
.mem-chip { text-align: center; padding: 0.75rem 0.5rem; border-radius: 8px; background: #f8f9fb; }
.mem-chip .num-big { font-size: 1.1rem; font-weight: 700; font-family: var(--mono); }
.mem-chip .label { font-size: 0.75rem; color: var(--muted); margin-top: 0.2rem; }

.tabs { display: flex; gap: 0.25rem; flex-wrap: wrap; margin-bottom: 0; border-bottom: 2px solid var(--border); padding-bottom: 0; }
.tab-btn { background: none; border: none; padding: 0.5rem 1rem; font-size: 0.85rem; font-weight: 600; color: var(--muted); cursor: pointer; border-bottom: 3px solid transparent; margin-bottom: -2px; transition: all 0.15s; border-radius: 6px 6px 0 0; }
.tab-btn:hover { color: var(--text); background: #f0f1f3; }
.tab-btn.active { color: var(--text); border-bottom-color: var(--dark); background: var(--card); }
.tab-panel { display: none; }
.tab-panel.active { display: block; }

.scenario-header { display: flex; align-items: center; flex-wrap: wrap; margin: 1.25rem 0 1rem; }
.scenario-header h3 { font-size: 1.15rem; }
.scenario-sub { color: var(--muted); font-size: 0.85rem; margin: 0 0 1rem; font-family: var(--mono); }
.chart-row { display: grid; grid-template-columns: 1fr 1fr; gap: 1rem; margin-bottom: 1.25rem; }
.chart-box { background: var(--card); border-radius: 10px; padding: 1rem 1.25rem; box-shadow: 0 1px 3px rgba(0,0,0,0.06); }

table { width: 100%; border-collapse: collapse; background: var(--card); border-radius: 10px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.06); margin: 0.75rem 0; }
th { background: var(--dark); color: #fff; padding: 0.65rem 0.75rem; text-align: left; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; }
td { padding: 0.55rem 0.75rem; border-bottom: 1px solid #f0f1f3; font-size: 0.88rem; }
tr:last-child td { border-bottom: none; }
tbody tr:hover { background: #f8f9fb; }
.ovh { color: var(--muted); font-size: 0.8rem; }

.radar-wrap { max-width: 540px; margin: 0 auto; }

.note-card { background: #fffbe6; border: 1px solid #f9dc73; border-radius: 8px; padding: 0.75rem 1rem; margin: 1rem 0; font-size: 0.88rem; }
.note-card strong { color: #876800; }

footer { text-align: center; color: #adb5bd; margin-top: 3rem; font-size: 0.8rem; padding: 1.5rem 0; border-top: 1px solid var(--border); }

@media (max-width: 768px) {
  .chart-row { grid-template-columns: 1fr; }
  .hero .wrap { flex-direction: column; align-items: flex-start; }
  .mem-grid { grid-template-columns: repeat(auto-fill, minmax(100px, 1fr)); }
}
@media print {
  .hero { background: #fff; color: #000; border-bottom: 2px solid #000; }
  .hero .meta { color: #666; }
  .tab-btn { display: none; }
  .tab-panel { display: block !important; page-break-inside: avoid; }
  .card, .chart-box, table { box-shadow: none; border: 1px solid #ddd; }
  body { background: #fff; }
}
"""


def fmt_num(value: float, digits: int = 1) -> str:
    """Thousand-separated, fixed-precision number."""
    if value >= 1000:
        return f"{value:,.{digits}f}"
    return f"{value:.{digits}f}"


def fmt_int(value: int) -> str:
    return f"{value:,}"


def fmt_bytes(bytes_: float) -> str:
    mb = bytes_ / (1024 * 1024)
    if mb >= 1000:
        return f"~{mb / 1024:.1f} GB"
    return f"~{round(mb)} MB"


def emit_executive_summary(summary: list[dict]) -> str:
    rows = []
    medals = ["🥇", "🥈", "🥉"]
    for i, s in enumerate(summary):
        rank = medals[i] if i < 3 else f"#{i + 1}"
        err_class = "error-cell" if s["max_err"] > 0.5 else ""
        rows.append(
            f'<tr>'
            f'<td class="rank-cell">{rank}</td>'
            f'<td><span class="badge" style="background:{GATEWAY_COLORS[s["gateway"]]}">{s["gateway"]}</span></td>'
            f'<td class="meta-cell">{s["stack"][0]} · {s["stack"][1]}</td>'
            f'<td class="num">{fmt_num(s["avg_rps"])}</td>'
            f'<td class="{err_class}">{s["max_err"]:.1f}%</td>'
            f'<td>{s["coverage"]}</td>'
            f'<td class="meta-cell">~{round(s["peak_rss"])} MB</td>'
            f'</tr>'
        )
    return (
        '<h2 class="section-title">Executive Summary</h2>\n'
        '<div class="card" style="margin-bottom:1rem">\n'
        '<table class="ranking-table">\n'
        '<thead><tr>'
        '<th style="text-align:center">Rank</th>'
        '<th>Gateway</th>'
        '<th>Stack</th>'
        '<th style="text-align:right">Avg RPS</th>'
        '<th>Max Errors</th>'
        '<th>Policies</th>'
        '<th>Peak RSS</th>'
        '</tr></thead>\n'
        '<tbody>\n' + "\n".join(rows) + '\n</tbody>\n'
        '</table>\n</div>'
    )


def emit_memory_grid(summary: list[dict]) -> str:
    chips = []
    for s in sorted(summary, key=lambda r: r["peak_rss"]):
        chips.append(
            f'<div class="mem-chip">'
            f'<div class="num-big" style="color:{GATEWAY_COLORS[s["gateway"]]}">~{round(s["peak_rss"])} MB</div>'
            f'<div class="label">{s["gateway"]}</div>'
            f'</div>'
        )
    return (
        '<h2 class="section-title">Memory Footprint (peak RSS across 12 policies)</h2>\n'
        '<div class="card"><div class="mem-grid">\n' + "\n".join(chips) + '\n</div></div>'
    )


def emit_radar() -> str:
    return (
        '<h2 class="section-title">Overall Profile</h2>\n'
        '<div class="card"><div class="radar-wrap"><canvas id="radarChart"></canvas></div></div>'
    )


def emit_policy_tabs(index: dict, rows_by_policy: dict) -> str:
    buttons = []
    panels = []
    for i, policy in enumerate(POLICY_ORDER):
        if policy not in index:
            continue
        active = " active" if i == 0 else ""
        buttons.append(
            f'<button class="tab-btn{active}" data-tab="tab-{policy}">{POLICY_LABEL[policy]}</button>'
        )
        panels.append(emit_policy_panel(policy, index[policy], rows_by_policy[policy], active))
    return (
        '<h2 class="section-title">Policy Details</h2>\n'
        '<div class="tabs">\n' + "\n".join(buttons) + '\n</div>\n' +
        "\n".join(panels)
    )


def emit_policy_panel(policy: str, cells: dict, all_cells: list[dict], active: str) -> str:
    # Latency winner = best p95 across cells with valid timing data;
    # throughput winner = best RPS regardless of timing. Splitting the two
    # prevents a broken-instrumentation cell (0ms everywhere) from claiming
    # the "winner" crown solely on RPS count.
    sorted_by_rps  = sorted(cells.values(), key=lambda c: c["rps"], reverse=True)
    valid_timing   = [c for c in cells.values() if not c["timing_broken"]]
    sorted_by_p95  = sorted(valid_timing, key=lambda c: c["p95"]) if valid_timing else []
    if not sorted_by_rps:
        return f'<div class="tab-panel{active}" id="tab-{policy}"><p class="meta-cell">No data for {policy}.</p></div>'

    # The reference-row for the "Δ p50" column is the fastest p95 cell
    # (a latency-trustworthy gateway), not the highest-RPS one — otherwise
    # Δ gets computed against a row whose own p50 is 0ms and every other
    # gateway looks 100% "slower".
    lat_winner = sorted_by_p95[0] if sorted_by_p95 else None
    rps_winner = sorted_by_rps[0]

    if lat_winner and rps_winner["gateway"] != lat_winner["gateway"]:
        winner_tag = (
            f'<span class="winner-tag" style="border-color:{GATEWAY_COLORS.get(rps_winner["gateway"], "#000")}">'
            f'🏆 Throughput: <strong>{rps_winner["gateway"]}</strong> — {fmt_num(rps_winner["rps"])} RPS'
            f'</span>'
            f'<span class="winner-tag" style="border-color:{GATEWAY_COLORS.get(lat_winner["gateway"], "#000")}">'
            f'⏱️ Latency: <strong>{lat_winner["gateway"]}</strong> — p95 {lat_winner["p95"]:.2f} ms'
            f'</span>'
        )
    else:
        w = lat_winner or rps_winner
        winner_tag = (
            f'<span class="winner-tag" style="border-color:{GATEWAY_COLORS.get(w["gateway"], "#000")}">'
            f'🏆 Winner: <strong>{w["gateway"]}</strong> — {fmt_num(w["rps"])} RPS · p95 {w["p95"]:.2f} ms'
            f'</span>'
        )

    # Scenario id from any PASS cell (they all share the canonical sNN-*-http
    # pair for this policy, per docs/POLICIES.md).
    scenario_id = rps_winner["scenario"]

    # Use latency-winner as the overhead reference so numbers stay meaningful
    # across cells; fall back to RPS winner when no valid timing exists.
    ref = lat_winner or rps_winner

    rows_html = []
    for c in sorted_by_rps:
        is_rps_winner = (c["gateway"] == rps_winner["gateway"])
        is_ref        = (c is ref)
        tr_class      = ' class="winner-row"' if (is_rps_winner or is_ref) else ""
        badge_tail    = ""
        if is_rps_winner and is_ref:
            badge_tail = " 🏆"
        elif is_rps_winner:
            badge_tail = " 🏆"
        elif is_ref:
            badge_tail = " ⏱️"

        if c["timing_broken"]:
            p50_str = '<span class="meta-cell" title="k6 timing instrumentation returned zeros for all requests on this gateway">N/A ⚠️</span>'
            p95_str = p50_str
            max_str = p50_str
            ovh     = '<span class="ovh">timing N/A</span>'
        else:
            p50_str = f'{c["p50"]:.3f}'
            p95_str = f'{c["p95"]:.3f}'
            max_str = f'{c["max"]:.3f}'
            delta_p50 = c["p50"] - ref["p50"]
            if is_ref:
                ovh = '<span class="ovh">latency ref</span>'
            elif ref["p50"] > 0:
                sign = "+" if delta_p50 >= 0 else ""
                pct  = delta_p50 / ref["p50"] * 100
                ovh  = f'<span class="ovh">{sign}{delta_p50:.3f}ms ({sign}{pct:.0f}%)</span>'
            else:
                ovh = '<span class="ovh">n/a</span>'

        err_class  = "error-cell" if c["err_rate"] > 0.005 else ""
        err_text   = f'{c["err_rate"] * 100:.1f}%'

        rows_html.append(
            f'<tr{tr_class}>'
            f'<td><span class="badge" style="background:{GATEWAY_COLORS.get(c["gateway"], "#888")}">{c["gateway"]}</span>{badge_tail}</td>'
            f'<td class="num">{fmt_num(c["rps"])}</td>'
            f'<td class="num">{p50_str}</td>'
            f'<td class="num">{p95_str}</td>'
            f'<td class="num">{max_str}</td>'
            f'<td class="num">{fmt_int(c["reqs"])}</td>'
            f'<td class="{err_class}">{err_text}</td>'
            f'<td class="num">{ovh}</td>'
            f'</tr>'
        )

    # Tail-append any EXCLUDED rows for this policy so reviewers can see
    # which gateways intentionally opted out of this cell (tyk's JWT / body
    # rewrite FEATURE-MISSING entries live here).
    excluded = [r for r in all_cells if r["verdict"] == "EXCLUDED"]
    for r in excluded:
        rows_html.append(
            f'<tr class="excluded-row">'
            f'<td><span class="badge" style="background:{GATEWAY_COLORS.get(r["gateway"], "#888")}">{r["gateway"]}</span></td>'
            f'<td class="excluded-cell" colspan="7">FEATURE-MISSING — see <code>docs/POLICIES.md § {r["gateway"].capitalize()} deviations</code>.</td>'
            f'</tr>'
        )

    return (
        f'<div class="tab-panel{active}" id="tab-{policy}">\n'
        f'<div class="scenario-header"><h3>{POLICY_LABEL[policy]}</h3>{winner_tag}</div>\n'
        f'<p class="scenario-sub">scenario <code>{scenario_id}</code> · load <code>p1-baseline</code></p>\n'
        f'<div class="chart-row">'
        f'<div class="chart-box"><canvas id="chart-rps-{policy}"></canvas></div>'
        f'<div class="chart-box"><canvas id="chart-lat-{policy}"></canvas></div>'
        f'</div>\n'
        f'<table><thead><tr>'
        f'<th>Gateway</th><th>RPS ↓</th><th>p50 (ms)</th><th>p95 (ms)</th><th>Max (ms)</th>'
        f'<th>Total Reqs</th><th>Errors</th><th>Δ p50 vs winner</th>'
        f'</tr></thead><tbody>\n' + "\n".join(rows_html) + '\n</tbody></table>\n'
        f'</div>'
    )


def emit_footer(meta: dict) -> str:
    pass_count = meta["pass_count"]
    excluded   = meta["excluded_count"]
    fail_count = meta["fail_count"]
    run_ids    = meta["run_ids"]
    return (
        '<footer>\n'
        f'path-A matrix · {pass_count} PASS + {excluded} EXCLUDED + {fail_count} FAIL '
        f'across {len(run_ids)} run(s)<br>\n'
        f'Rendered by <code>scripts/render-html-report.py</code> from '
        f'<code>{meta["source_csv"]}</code>\n'
        '</footer>'
    )


def emit_script(chart_data: dict, radar_labels: list[str], radar_datasets: list[dict]) -> str:
    # POLICY_ORDER is passed through only for the policies we actually have
    # chart data for (omits absent policies if the input CSV is partial).
    policies_with_data = [p for p in POLICY_ORDER if chart_data.get(p)]
    return (
        "<script>\n"
        f"const POLICIES = {json.dumps(policies_with_data)};\n"
        f"const CHART_DATA = {json.dumps({k: v for k, v in chart_data.items() if v})};\n"
        f"const RADAR_LABELS = {json.dumps(radar_labels)};\n"
        f"const RADAR_DATASETS = {json.dumps(radar_datasets)};\n"
        """
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById(btn.dataset.tab).classList.add('active');
  });
});

Chart.defaults.font.family = "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif";
Chart.defaults.font.size = 12;
Chart.defaults.plugins.legend.display = false;

POLICIES.forEach(policy => {
  const d = CHART_DATA[policy];
  if (!d) return;

  new Chart(document.getElementById('chart-rps-' + policy), {
    type: 'bar',
    data: { labels: d.labels, datasets: [{ data: d.rps, backgroundColor: d.colors, borderRadius: 4 }] },
    options: {
      indexAxis: 'y',
      responsive: true,
      plugins: {
        title: { display: true, text: 'Requests/sec (higher is better)', font: { size: 13, weight: '600' }, padding: { bottom: 12 } }
      },
      scales: {
        x: { beginAtZero: true, grid: { color: '#f0f1f3' }, ticks: { font: { family: "var(--mono)" } } },
        y: { grid: { display: false }, ticks: { font: { weight: '600' } } }
      }
    }
  });

  new Chart(document.getElementById('chart-lat-' + policy), {
    type: 'bar',
    data: {
      labels: d.labels,
      datasets: [
        { label: 'p50', data: d.p50, backgroundColor: '#60a5fa', borderRadius: 4 },
        { label: 'p95', data: d.p95, backgroundColor: '#f87171', borderRadius: 4 }
      ]
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      plugins: {
        title: { display: true, text: 'Latency ms (lower is better)', font: { size: 13, weight: '600' }, padding: { bottom: 12 } },
        legend: { display: true, position: 'bottom', labels: { boxWidth: 12 } }
      },
      scales: {
        x: { beginAtZero: true, grid: { color: '#f0f1f3' }, ticks: { font: { family: "var(--mono)" } } },
        y: { grid: { display: false }, ticks: { font: { weight: '600' } } }
      }
    }
  });
});

if (RADAR_DATASETS.length > 0) {
  new Chart(document.getElementById('radarChart'), {
    type: 'radar',
    data: {
      labels: RADAR_LABELS,
      datasets: RADAR_DATASETS.map(ds => ({ ...ds, borderWidth: 2, pointRadius: 3, fill: true }))
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: true, position: 'bottom', labels: { boxWidth: 12, padding: 16 } },
        title: { display: true, text: 'Relative RPS by policy (% of best)', font: { size: 14, weight: '600' }, padding: { bottom: 8 } }
      },
      scales: {
        r: {
          beginAtZero: true,
          max: 100,
          ticks: { stepSize: 25, font: { size: 10 }, backdropColor: 'transparent' },
          grid: { color: '#e5e7eb' },
          pointLabels: { font: { size: 11, weight: '500' } }
        }
      }
    }
  });
}
</script>
"""
    )


# ---- Main -------------------------------------------------------------------

def render(rows: list[dict], title: str, env_line: str, source_csv: str) -> str:
    index = build_index(rows)
    rows_by_policy = defaultdict(list)
    for r in rows:
        rows_by_policy[r["policy"]].append(r)

    summary = compute_summary(index)
    chart_data = compute_chart_data(index)
    radar_labels, radar_datasets = compute_radar(index)

    meta = {
        "pass_count":     sum(1 for r in rows if r["verdict"] == "PASS"),
        "excluded_count": sum(1 for r in rows if r["verdict"] == "EXCLUDED"),
        "fail_count":     sum(1 for r in rows if r["verdict"] == "FAIL"),
        "run_ids":        sorted({r["run_id"] for r in rows}),
        "source_csv":     source_csv,
    }

    generated_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    head = (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n'
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
        f'<title>{html.escape(title)}</title>\n'
        '<script src="https://cdn.jsdelivr.net/npm/chart.js@4"></script>\n'
        f'<style>{CSS}</style>\n'
        '</head>\n<body>\n'
    )

    hero = (
        '<header class="hero">\n<div class="wrap">\n<div>\n'
        f'<h1>{html.escape(title)}</h1>\n'
        f'<p class="meta">Generated {generated_at} &nbsp;&bull;&nbsp; {html.escape(env_line)}</p>\n'
        '</div>\n</div>\n</header>\n\n<div class="wrap">\n'
    )

    broken_gateways = sorted({r["gateway"] for r in rows if r.get("timing_broken")})
    broken_note = ""
    if broken_gateways:
        broken_note = (
            ' <strong>Known measurement gap:</strong> k6\'s <code>http_req_duration</code> '
            f'histogram returned all-zeros for <em>{", ".join(broken_gateways)}</em> on this '
            'harness (the request counter is unaffected, so RPS is trustworthy). '
            'Such cells are flagged <code>N/A ⚠️</code> in the latency columns and '
            'excluded from the latency-winner tag; the ⏱️ latency-reference row is '
            'picked from the fastest gateway with valid timing data. Root cause is '
            'still being traced (independently of this harness).'
        )

    context_note = (
        '<div class="note-card">\n'
        '<strong>How to read this report.</strong> '
        'Every cell is one <code>(gateway, policy, load profile)</code> combination. '
        'RPS is <em>closed-loop iteration cadence</em> — apples-to-apples with '
        'the <a href="https://github.com/api7/apisix-benchmark">api7/apisix-benchmark</a> and '
        '<a href="https://github.com/jkaninda/goma-gateway-vs-traefik">goma-gateway-vs-traefik</a> '
        'references, not absolute-arrival-rate. '
        'Policies <code>p04/p06/p12</code> intentionally saturate the rate-limiter, so '
        'most of their traffic lands in <code>policy_4xx_expected</code> (the 429 bucket) — '
        'this is counted as a 2xx-equivalent pass, not an error. '
        'Error column shows <code>policy_4xx_unexpected + policy_5xx_unexpected</code> only.'
        f'{broken_note}'
        '</div>'
    )

    body = [
        hero,
        context_note,
        emit_executive_summary(summary),
        emit_memory_grid(summary),
        emit_radar(),
        emit_policy_tabs(index, rows_by_policy),
        emit_footer(meta),
        '</div>\n',
        emit_script(chart_data, radar_labels, radar_datasets),
        '</body>\n</html>\n',
    ]

    return head + "\n".join(body)


def main() -> int:
    print(
        "[deprecated] scripts/render-html-report.py — use `bench report` "
        "(see orchestrator/README.md). This Python prototype is kept only "
        "for legacy CSV-only runs and will be removed in a future cycle.",
        file=sys.stderr,
    )
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input",  required=True, help="combined matrix CSV")
    ap.add_argument("--output", required=True, help="output HTML path")
    ap.add_argument("--title",  default="API Gateway Benchmark — Path A")
    ap.add_argument(
        "--env",
        default="Apple Silicon Docker Desktop · k6 v0.58 · p1-baseline (10 VUs × 60s closed-loop)",
    )
    args = ap.parse_args()

    src = pathlib.Path(args.input)
    if not src.is_file():
        print(f"input not found: {src}", file=sys.stderr)
        return 2

    rows = load_matrix(src)
    dst = pathlib.Path(args.output)
    dst.parent.mkdir(parents=True, exist_ok=True)

    html_out = render(rows, args.title, args.env, str(src))
    dst.write_text(html_out, encoding="utf-8")

    print(f"wrote: {dst}  ({len(rows)} rows, "
          f"{sum(1 for r in rows if r['verdict'] == 'PASS')} PASS, "
          f"{sum(1 for r in rows if r['verdict'] == 'EXCLUDED')} EXCLUDED, "
          f"{sum(1 for r in rows if r['verdict'] == 'FAIL')} FAIL)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
