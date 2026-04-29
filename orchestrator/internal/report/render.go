package report

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// Options carries the user-tunable knobs the renderer accepts. The
// defaults are sensible — only Title is mandatory.
type Options struct {
	Title             string
	EnvLine           string
	LogoPath          string
	OutputPath        string
	UnstableThreshold float64 // (max-min)/mean RPS spread; 0.05 = 5%
	HowToRead         string  // free-form note inserted under the hero
	HeroNote          string  // appended to HowToRead when set; usually
	// populated by the renderer when it sees
	// timing-broken cells.
}

// DefaultHowToRead is the canonical reviewer-facing note. Mirrors
// the Python prototype's blurb so reviewers see the same framing.
const DefaultHowToRead = `Every cell is one <code>(gateway, policy, load profile)</code> combination. ` +
	`RPS is <em>closed-loop iteration cadence</em> — apples-to-apples with the ` +
	`<a href="https://github.com/api7/apisix-benchmark">api7/apisix-benchmark</a> and ` +
	`<a href="https://github.com/jkaninda/goma-gateway-vs-traefik">goma-gateway-vs-traefik</a> references, ` +
	`not absolute-arrival rate. Policies <code>p04 / p06 / p12</code> intentionally saturate the rate-limiter, ` +
	`so most of their traffic lands in <code>policy_4xx_expected</code> (the 429 bucket) — counted as a ` +
	`pass, not an error. The "Errors" columns surface ` +
	`<code>policy_4xx_unexpected + policy_5xx_unexpected</code> only.`

// Render reads cells.jsonl + manifest.json, builds the view model,
// executes the embedded template and writes the resulting HTML to
// disk. Returns the absolute path of the file it wrote.
func Render(loaded *Loaded, opts Options) (string, error) {
	if loaded == nil || len(loaded.Cells) == 0 {
		return "", fmt.Errorf("render: no cells to render")
	}

	tmplSrc, css, js, err := loadAssets()
	if err != nil {
		return "", err
	}

	idx := BuildIndex(loaded.Cells, opts.UnstableThreshold)
	loads := loadsPresent(idx)

	view := &View{
		Title:       firstNonEmpty(opts.Title, defaultTitle(loaded)),
		GeneratedAt: time.Now().UTC().Format("2006-01-02 15:04 UTC"),
		EnvLine:     firstNonEmpty(opts.EnvLine, defaultEnvLine(loaded)),
		LogoDataURI: "",
		HowToRead:   firstNonEmpty(opts.HowToRead, DefaultHowToRead),
		Manifest:    loaded.Manifest,
		Summary:     BuildSummary(idx, loads),
		Tabs:        BuildTabs(idx, loads),
		Footer:      BuildFooter(idx),
	}
	view.MemoryChips = BuildMemoryChips(view.Summary)
	view.HasResourceData = len(view.MemoryChips) > 0

	// Radar focuses on p1-baseline by default — the load profile we
	// expect to be present in every public report. Falls back to the
	// first available load when p1-baseline is missing.
	radarLoad := pickRadarLoad(loads)
	view.RadarLabels, view.RadarSeries = BuildRadar(idx, radarLoad)

	// Append the timing-broken disclaimer when relevant. We surface
	// the gateway names so reviewers can map the warning to the table.
	broken := brokenGateways(loaded.Cells)
	if len(broken) > 0 {
		view.HeroNote = brokenNote(broken)
	} else if opts.HeroNote != "" {
		view.HeroNote = opts.HeroNote
	}

	view.Downloads = computeDownloads(loaded, opts.OutputPath)
	if opts.LogoPath != "" {
		logo, err := imageDataURI(opts.LogoPath)
		if err != nil {
			return "", err
		}
		view.LogoDataURI = logo
	} else {
		logo, err := embeddedLogoDataURI()
		if err != nil {
			return "", err
		}
		view.LogoDataURI = logo
	}

	if b, err := jsonStr(view.RadarLabels); err == nil {
		view.RadarLabelsJSON = b
	} else {
		return "", fmt.Errorf("encode radar labels: %w", err)
	}
	if b, err := jsonStr(view.RadarSeries); err == nil {
		view.RadarSeriesJSON = b
	} else {
		return "", fmt.Errorf("encode radar series: %w", err)
	}

	policies := make([]string, 0, len(view.Tabs))
	for _, t := range view.Tabs {
		policies = append(policies, t.Policy)
	}
	if b, err := jsonStr(policies); err == nil {
		view.PoliciesJSON = b
	} else {
		return "", fmt.Errorf("encode policies: %w", err)
	}
	chartJSON, err := BuildChartDataJSON(view.Tabs)
	if err != nil {
		return "", fmt.Errorf("build chart data: %w", err)
	}
	view.ChartDataJSON = chartJSON

	// Compose the template-facing fields the template expects.
	tplCtx := struct {
		*View
		CSS      string
		ScriptJS string
	}{view, css, js}

	t, err := template.New("report").Funcs(templateFuncs()).Parse(tmplSrc)
	if err != nil {
		return "", fmt.Errorf("parse template: %w", err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, tplCtx); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}

	out := opts.OutputPath
	if out == "" {
		out = filepath.Join(loaded.RunDir, "report.html")
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(out, buf.Bytes(), 0o644); err != nil {
		return "", err
	}
	return out, nil
}

func imageDataURI(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read logo %s: %w", path, err)
	}
	ext := strings.ToLower(filepath.Ext(path))
	mime := "image/png"
	switch ext {
	case ".svg":
		mime = "image/svg+xml"
	case ".jpg", ".jpeg":
		mime = "image/jpeg"
	case ".webp":
		mime = "image/webp"
	case ".gif":
		mime = "image/gif"
	}
	return "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data), nil
}

func embeddedLogoDataURI() (string, error) {
	data, err := assets.ReadFile("assets/logo-cropped.png")
	if err != nil {
		return "", fmt.Errorf("read embedded logo: %w", err)
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(data), nil
}

// -----------------------------------------------------------------------------
// helpers
// -----------------------------------------------------------------------------

func loadsPresent(idx *Index) []string {
	seen := map[string]struct{}{}
	for _, byGW := range idx.Buckets {
		for _, byLoad := range byGW {
			for load := range byLoad {
				seen[load] = struct{}{}
			}
		}
	}
	out := []string{}
	for _, l := range LoadOrder {
		if _, ok := seen[l]; ok {
			out = append(out, l)
		}
	}
	// Stable tail for any unknown load (keeps unit-test determinism)
	known := map[string]struct{}{}
	for _, l := range out {
		known[l] = struct{}{}
	}
	for l := range seen {
		if _, ok := known[l]; ok {
			continue
		}
		out = append(out, l)
	}
	if len(out) > len(LoadOrder) {
		// Sort the tail of unknowns for determinism.
		tail := out[len(LoadOrder):]
		sort.Strings(tail)
	}
	return out
}

func pickRadarLoad(loads []string) string {
	for _, l := range loads {
		if l == "p1-baseline" {
			return l
		}
	}
	if len(loads) > 0 {
		return loads[0]
	}
	return "p1-baseline"
}

func brokenGateways(cells []aggregate.Cell) []string {
	seen := map[string]struct{}{}
	for _, c := range cells {
		if c.TimingBroken {
			seen[c.Gateway] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for g := range seen {
		out = append(out, g)
	}
	sort.Strings(out)
	return out
}

func brokenNote(gateways []string) string {
	return `<strong>Known measurement gap:</strong> k6's <code>http_req_duration</code> ` +
		`histogram returned all-zeros for <em>` + template.HTMLEscapeString(strings.Join(gateways, ", ")) +
		`</em> on this harness (the request counter is unaffected, so RPS stays trustworthy). ` +
		`Such cells are flagged <code>N/A ⚠️</code> in the latency columns and ` +
		`excluded from the latency-winner pick; the ⏱️ latency-reference row is ` +
		`picked from the fastest gateway with valid timing data.`
}

func defaultTitle(l *Loaded) string {
	if l.Manifest != nil && l.Manifest.RunID != "" {
		return "API Gateway Benchmark — " + l.Manifest.RunID
	}
	if len(l.RunIDs) > 0 {
		return "API Gateway Benchmark — " + l.RunIDs[0]
	}
	return "API Gateway Benchmark"
}

func defaultEnvLine(l *Loaded) string {
	if l.Manifest == nil {
		return "Local Docker · k6 · closed-loop"
	}
	parts := []string{}
	if l.Manifest.Mode != "" {
		parts = append(parts, l.Manifest.Mode)
	}
	if l.Manifest.Host.Kernel != "" {
		parts = append(parts, l.Manifest.Host.Kernel)
	} else if l.Manifest.Host.OS != "" {
		parts = append(parts, l.Manifest.Host.OS+"/"+l.Manifest.Host.Arch)
	}
	if l.Manifest.K6.Image != "" {
		// strip "@digest" tail; the digest already lands in the hero footer.
		k6 := l.Manifest.K6.Image
		if i := strings.Index(k6, "@"); i >= 0 {
			k6 = k6[:i]
		}
		parts = append(parts, "k6 "+k6)
	}
	if l.Manifest.Repetitions > 0 {
		parts = append(parts, fmt.Sprintf("%d rep(s)", l.Manifest.Repetitions))
	}
	if l.Manifest.Notes != "" {
		parts = append(parts, l.Manifest.Notes)
	}
	if len(parts) == 0 {
		return "Local Docker · k6"
	}
	return strings.Join(parts, " · ")
}

// computeDownloads picks the standard sibling files (manifest.json,
// matrix.csv, cells.jsonl, matrix.md) and turns them into relative
// links from the report.html location.
func computeDownloads(loaded *Loaded, outputPath string) Downloads {
	if loaded.RunDir == "" {
		return Downloads{}
	}
	out := Downloads{}
	dir := loaded.RunDir
	relTo := outputPath
	if relTo == "" {
		relTo = filepath.Join(dir, "report.html")
	}
	relDir := filepath.Dir(relTo)

	candidates := map[string]*string{
		"manifest.json": &out.Manifest,
		"matrix.csv":    &out.CSV,
		"cells.jsonl":   &out.JSONL,
		"matrix.md":     &out.Markdown,
	}
	for name, dst := range candidates {
		full := filepath.Join(dir, name)
		if _, err := os.Stat(full); err != nil {
			continue
		}
		rel, err := filepath.Rel(relDir, full)
		if err != nil {
			continue
		}
		*dst = filepath.ToSlash(rel)
	}
	return out
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func jsonStr(v interface{}) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
