package report

import (
	"embed"
	"fmt"
	"html/template"
	"math"
	"strings"
)

// Static assets (HTML template + inline CSS + inline JS hook) are
// embedded into the binary so `bench report` works on hosts that
// don't have the source tree mounted.
//
//go:embed assets/report.html.tmpl assets/styles.css assets/report.js assets/logo-cropped.png
var assets embed.FS

// loadAssets returns (template source, css source, js source).
func loadAssets() (string, string, string, error) {
	tmpl, err := assets.ReadFile("assets/report.html.tmpl")
	if err != nil {
		return "", "", "", fmt.Errorf("embed: %w", err)
	}
	css, err := assets.ReadFile("assets/styles.css")
	if err != nil {
		return "", "", "", fmt.Errorf("embed: %w", err)
	}
	js, err := assets.ReadFile("assets/report.js")
	if err != nil {
		return "", "", "", fmt.Errorf("embed: %w", err)
	}
	return string(tmpl), string(css), string(js), nil
}

// templateFuncs declares every helper the template references. Kept
// short on purpose — the model layer pre-computes anything that
// needs more than a one-line projection.
//
// `safe`, `cssSafe`, and `jsSafe` are deliberately separate so the
// html/template auto-escaper can apply context-correct sanitisation:
// HTML fragments stay typed as template.HTML, the inline stylesheet
// as template.CSS, and the inline JS hook as template.JS.
func templateFuncs() template.FuncMap {
	return template.FuncMap{
		"esc":     func(v interface{}) string { return template.HTMLEscapeString(fmt.Sprint(v)) },
		"safe":    func(v interface{}) template.HTML { return template.HTML(fmt.Sprint(v)) },
		"cssSafe": func(v interface{}) template.CSS { return template.CSS(fmt.Sprint(v)) },
		"jsSafe":  func(v interface{}) template.JS { return template.JS(fmt.Sprint(v)) },
		"urlSafe": func(v interface{}) template.URL { return template.URL(fmt.Sprint(v)) },
		"default": func(v, fallback string) string {
			if strings.TrimSpace(v) == "" {
				return fallback
			}
			return v
		},
		"color":            func(gw string) string { return GatewayColors[gw] },
		"k6Version":        k6Version,
		"shortSHA":         shortSHA,
		"shortDigest":      shortDigest,
		"rank":             rankSymbol,
		"fmtFloat":         fmtFloat,
		"fmtInt":           fmtInt,
		"fmtBytes":         fmtBytes,
		"fmtMaybeMB":       fmtMaybeMB,
		"fmtRSSPair":       fmtRSSPair,
		"fmtBps":           fmtBps,
		"fmtPct":           fmtPct,
		"unexpectedErrors": unexpectedErrors,
		"bottleneckClass":  bottleneckClass,
		"showBottleneck":   showBottleneck,
		"deltaP50":         deltaP50,
	}
}

func k6Version(image string) string {
	if i := strings.Index(image, "@"); i >= 0 {
		image = image[:i]
	}
	image = strings.TrimSpace(image)
	if image == "" {
		return "unknown"
	}
	if i := strings.LastIndex(image, ":"); i >= 0 && i+1 < len(image) {
		return image[i+1:]
	}
	return image
}

func shortSHA(s string) string {
	if len(s) < 7 {
		return s
	}
	return s[:7]
}

func shortDigest(s string) string {
	// "sha256:abcdef…" → "sha256:abcdef…" trimmed to 14 chars after
	// the colon so the hero footer stays compact but unambiguous.
	if i := strings.Index(s, ":"); i >= 0 && len(s) > i+15 {
		return s[:i+15] + "…"
	}
	return s
}

func rankSymbol(i int) string {
	switch i {
	case 0:
		return "🥇"
	case 1:
		return "🥈"
	case 2:
		return "🥉"
	default:
		return fmt.Sprintf("#%d", i+1)
	}
}

func fmtFloat(v interface{}, digits int) string {
	f, ok := toFloat(v)
	if !ok {
		return "—"
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "—"
	}
	if digits < 0 {
		digits = 0
	}
	if f >= 1000 {
		// thousand-separated — Go has no %, so we format manually.
		return commafy(fmt.Sprintf("%.*f", digits, f))
	}
	return fmt.Sprintf("%.*f", digits, f)
}

func fmtInt(v interface{}) string {
	f, ok := toFloat(v)
	if !ok {
		return "—"
	}
	return commafy(fmt.Sprintf("%d", int64(f)))
}

func fmtBytes(v interface{}) string {
	f, ok := toFloat(v)
	if !ok || f == 0 {
		return "—"
	}
	mb := f / (1024 * 1024)
	if mb >= 1024 {
		return fmt.Sprintf("~%.1f GB", mb/1024)
	}
	return fmt.Sprintf("~%d MB", int(math.Round(mb)))
}

func fmtRSSPair(peak, steady int64) string {
	if peak <= 0 && steady <= 0 {
		return "—"
	}
	return fmt.Sprintf("%s / %s", fmtBytes(peak), fmtBytes(steady))
}

func fmtMaybeMB(v interface{}) string {
	f, ok := toFloat(v)
	if !ok || f <= 0 {
		return "—"
	}
	return fmt.Sprintf("~%.0f MB", f)
}

func unexpectedErrors(c Cell) int64 {
	return c.Policy5xxUnexpected + c.Policy4xxUnexpected
}

func fmtBps(v interface{}) string {
	f, ok := toFloat(v)
	if !ok || f == 0 {
		return "—"
	}
	mbs := f / (1024 * 1024)
	if mbs >= 1 {
		return fmt.Sprintf("%.1f MB/s", mbs)
	}
	kbs := f / 1024
	return fmt.Sprintf("%.0f KB/s", kbs)
}

func fmtPct(v interface{}) string {
	f, ok := toFloat(v)
	if !ok || f <= 0 {
		return "—"
	}
	return fmt.Sprintf("%.0f%%", f)
}

func bottleneckClass(v string) string {
	v = strings.TrimSpace(strings.ToLower(v))
	switch v {
	case "cpu", "ram", "disk", "network":
		return v
	case "not saturated":
		return "ok"
	default:
		return "unknown"
	}
}

func showBottleneck(v string) bool {
	v = strings.TrimSpace(strings.ToLower(v))
	return v == "cpu" || v == "ram" || v == "disk" || v == "network"
}

func deltaP50(c Cell, ref *Cell) string {
	if c.TimingBroken {
		return "timing N/A"
	}
	if ref == nil {
		return "n/a"
	}
	if c.Gateway == ref.Gateway {
		return "latency ref"
	}
	if ref.HTTPReqDurationP50 <= 0 {
		return "n/a"
	}
	d := c.HTTPReqDurationP50 - ref.HTTPReqDurationP50
	pct := d / ref.HTTPReqDurationP50 * 100
	sign := ""
	if d > 0 {
		sign = "+"
	}
	return fmt.Sprintf("%s%.3fms (%s%.0f%%)", sign, d, sign, pct)
}

func commafy(s string) string {
	// Insert thousands separators into the integer part of a numeric
	// string. Handles optional decimals.
	dot := strings.Index(s, ".")
	intPart := s
	frac := ""
	if dot >= 0 {
		intPart = s[:dot]
		frac = s[dot:]
	}
	// Track sign so we don't insert a comma after the leading "-".
	sign := ""
	if strings.HasPrefix(intPart, "-") {
		sign = "-"
		intPart = intPart[1:]
	}
	n := len(intPart)
	if n <= 3 {
		return sign + intPart + frac
	}
	var b strings.Builder
	first := n % 3
	if first > 0 {
		b.WriteString(intPart[:first])
		if n > first {
			b.WriteByte(',')
		}
	}
	for i := first; i < n; i += 3 {
		b.WriteString(intPart[i : i+3])
		if i+3 < n {
			b.WriteByte(',')
		}
	}
	return sign + b.String() + frac
}

func toFloat(v interface{}) (float64, bool) {
	switch x := v.(type) {
	case float64:
		return x, true
	case float32:
		return float64(x), true
	case int:
		return float64(x), true
	case int32:
		return float64(x), true
	case int64:
		return float64(x), true
	case uint:
		return float64(x), true
	case uint32:
		return float64(x), true
	case uint64:
		return float64(x), true
	default:
		return 0, false
	}
}
