// report.js — currently empty. We keep this file as an extensibility
// hook so future client-side enhancements (sparklines, sortable
// columns, click-to-expand cell drawers) can land here without
// breaking the template's two-script split. Embedded by go:embed and
// inlined into the rendered HTML.

// Sortable tables. Any <table class="sortable"> with <th data-sort>
// headers becomes interactive: click toggles ascending/descending,
// click another column to switch the sort key. Excluded / failed
// rows (the ones with a single colspan cell) are pinned to the
// bottom regardless of direction so they don't drift through the
// numeric column when sorted.
//
// data-sort values:
//   numeric  — strip everything but digits/dot/minus and parse as
//              float. "N/A", "—", empty → sentinel (Infinity for asc,
//              -Infinity for desc) so missing cells settle at the
//              bottom in either direction.
//   string   — localeCompare.
//   coverage — "PASSED/TOTAL" → PASSED.
//   rss      — first numeric token of a "peak / steady" cell.
(function () {
  const SENTINEL_BIG = Number.POSITIVE_INFINITY;
  const SENTINEL_SMALL = Number.NEGATIVE_INFINITY;

  function parseNumeric(text) {
    if (!text) return null;
    // Strip ANSI / em-dash / N-A markers — they all mean "missing".
    if (/^(—|N\/A|n\/a)/i.test(text.trim())) return null;
    const match = text.replace(/,/g, '').match(/-?\d+(\.\d+)?/);
    if (!match) return null;
    const v = parseFloat(match[0]);
    return isFinite(v) ? v : null;
  }

  function parseCoverage(text) {
    const m = text.match(/(\d+)\s*\/\s*\d+/);
    return m ? parseInt(m[1], 10) : null;
  }

  function getSortValue(td, kind) {
    const text = (td.textContent || '').trim();
    if (kind === 'string') return text.toLowerCase();
    if (kind === 'coverage') return parseCoverage(text);
    // numeric and rss share the parser — rss happens to grab the
    // first number, which is exactly the "peak" value.
    return parseNumeric(text);
  }

  function compareFactory(kind, asc) {
    return function (a, b) {
      let av = getSortValue(a, kind);
      let bv = getSortValue(b, kind);
      if (kind === 'string') {
        return asc ? av.localeCompare(bv) : bv.localeCompare(av);
      }
      // numeric / coverage / rss — null sinks to the bottom in BOTH
      // directions so missing data never claims first place.
      if (av === null) av = asc ? SENTINEL_BIG : SENTINEL_SMALL;
      if (bv === null) bv = asc ? SENTINEL_BIG : SENTINEL_SMALL;
      return asc ? av - bv : bv - av;
    };
  }

  function sortTable(table, columnIndex, kind, asc) {
    const tbody = table.tBodies[0];
    if (!tbody) return;
    const rows = Array.from(tbody.rows);
    // Split into ranked rows (have a real cell at columnIndex) vs
    // tail rows (excluded/failed with a single colspan cell). Tail
    // rows always settle at the bottom in their original order.
    const ranked = [];
    const tail = [];
    for (const row of rows) {
      const cell = row.cells[columnIndex];
      const looksLikeTail =
        row.classList.contains('excluded-row') ||
        row.classList.contains('failed-row') ||
        !cell ||
        cell.colSpan > 1;
      (looksLikeTail ? tail : ranked).push(row);
    }
    ranked.sort((a, b) => {
      return compareFactory(kind, asc)(a.cells[columnIndex], b.cells[columnIndex]);
    });
    // Rebuild tbody in one pass — fewer reflows than per-row append.
    const frag = document.createDocumentFragment();
    for (const r of ranked) frag.appendChild(r);
    for (const r of tail) frag.appendChild(r);
    tbody.appendChild(frag);
  }

  function wireTable(table) {
    const headers = table.querySelectorAll('thead th[data-sort]');
    headers.forEach((th, idx) => {
      th.addEventListener('click', () => {
        const kind = th.dataset.sort;
        const wasAsc = th.classList.contains('sort-asc');
        const wasDesc = th.classList.contains('sort-desc');
        // Reset every header in this table, then mark the clicked
        // one with the new direction.
        headers.forEach((h) => h.classList.remove('sort-asc', 'sort-desc'));
        // First click on a numeric column starts descending (highest
        // RPS / largest RSS first — the natural "leaderboard" view);
        // first click on a string column starts ascending.
        const asc = wasDesc ? true : wasAsc ? false : kind === 'string';
        th.classList.add(asc ? 'sort-asc' : 'sort-desc');
        // Compute the column index from the header position, not
        // from idx, because nth-child counts every <th> not just
        // sortable ones.
        const all = Array.from(th.parentElement.children);
        sortTable(table, all.indexOf(th), kind, asc);
      });
    });
  }

  document.querySelectorAll('table.sortable').forEach(wireTable);
})();
