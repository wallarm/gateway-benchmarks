// Package aggregate is the Go reimplementation of
// scripts/aggregate-csv.sh — same column schema, same per-cell
// projection, but with richer typed structs that downstream
// reporters can consume without re-parsing the CSV.
//
// Inputs (per cell):
//
//	reports/<RUN_ID>/raw/<gateway>/<policy>__<load>__<scenario>/
//	├── k6-summary.json   ← required for PASS rows
//	├── excluded.json     ← present for FEATURE-MISSING rows
//	├── docker-stats.csv  ← optional sidecar output
//	└── parity.json       ← optional pre-cell parity report
//
// Outputs (per RunID):
//
//	reports/<RUN_ID>/matrix.csv     ← wide CSV (27 columns, identical
//	                                  to scripts/aggregate-csv.sh)
//	reports/<RUN_ID>/cells.jsonl    ← one JSON object per cell
//	reports/<RUN_ID>/matrix.md      ← optional markdown rollup
//
// The aggregator never overwrites raw/ artefacts; it only reads them.
package aggregate

import (
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/classify"
)

// Cell is the typed projection of one (gateway, policy, scenario, load)
// run. JSON tags match scripts/aggregate-csv.sh column names so the
// JSONL output is a strict superset of the CSV.
type Cell struct {
	Gateway      string `json:"gateway"`
	Policy       string `json:"policy"`
	Scenario     string `json:"scenario"`
	Load         string `json:"load"`
	RunID        string `json:"run_id"`
	Verdict      string `json:"verdict"`
	ParityStatus string `json:"parity_status"`

	HTTPReqs              int64   `json:"http_reqs"`
	HTTPReqRate           float64 `json:"http_req_rate"`
	IterDurationAvgMs     float64 `json:"iter_duration_avg_ms"`
	HTTPReqDurationP50    float64 `json:"http_req_duration_p50"`
	HTTPReqDurationP90    float64 `json:"http_req_duration_p90"`
	HTTPReqDurationP95    float64 `json:"http_req_duration_p95"`
	HTTPReqDurationP99    float64 `json:"http_req_duration_p99"`
	HTTPReqDurationMax    float64 `json:"http_req_duration_max"`
	HTTPReqFailedRate     float64 `json:"http_req_failed_rate"`
	Policy2xx             int64   `json:"policy_2xx"`
	Policy4xxExpected     int64   `json:"policy_4xx_expected"`
	Policy4xxUnexpected   int64   `json:"policy_4xx_unexpected"`
	Policy5xxUnexpected   int64   `json:"policy_5xx_unexpected"`
	ChecksTotal           int64   `json:"checks_total"`
	ChecksPasses          int64   `json:"checks_passes"`
	ChecksFails           int64   `json:"checks_fails"`
	MemRSSPeakBytes       int64   `json:"mem_rss_peak"`
	MemRSSSteadyBytes     int64   `json:"mem_rss_steady"`
	CPUPctPeak            float64 `json:"cpu_pct_peak"`
	CPUPctSteady          float64 `json:"cpu_pct_steady"`

	// Derived; not in the canonical CSV but persisted to JSONL for
	// downstream reporters.
	Health        classify.Health `json:"health,omitempty"`
	TimingBroken  bool            `json:"timing_broken,omitempty"`
	OutputDirRel  string          `json:"output_dir,omitempty"`
}

// Aggregator collects per-cell artefacts under reports/<RunID>/raw.
type Aggregator struct {
	RepoRoot string
	RunID    string
}

// Collect walks the raw/ tree once and returns one Cell per
// (gateway, policy, load, scenario) tuple. PASS rows come from
// k6-summary.json; EXCLUDED rows come from excluded.json. Cells are
// returned in canonical (gateway → policy → load → scenario) order.
func (a *Aggregator) Collect() ([]Cell, error) {
	rawRoot := filepath.Join(a.RepoRoot, "reports", a.RunID, "raw")
	st, err := os.Stat(rawRoot)
	if err != nil || !st.IsDir() {
		return nil, fmt.Errorf("aggregate: no raw/ tree under reports/%s", a.RunID)
	}

	var cells []Cell
	walkErr := filepath.WalkDir(rawRoot, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || (filepath.Base(path) != "k6-summary.json" && filepath.Base(path) != "excluded.json") {
			return nil
		}

		cellDir := filepath.Dir(path)
		cellName := filepath.Base(cellDir)
		gateway := filepath.Base(filepath.Dir(cellDir))

		policy, load, scenario, ok := splitCellName(cellName)
		if !ok {
			return nil // not a benchmark cell directory
		}

		cell := Cell{
			Gateway:      gateway,
			Policy:       policy,
			Scenario:     scenario,
			Load:         load,
			RunID:        a.RunID,
			OutputDirRel: filepath.ToSlash(strings.TrimPrefix(cellDir, a.RepoRoot+string(os.PathSeparator))),
		}

		switch filepath.Base(path) {
		case "k6-summary.json":
			cell.Verdict = "PASS"
			if err := loadK6Summary(path, &cell); err != nil {
				return nil
			}
		case "excluded.json":
			cell.Verdict = "EXCLUDED"
			loadExcluded(path, &cell)
		}

		// Optional sidecars
		loadParity(filepath.Join(cellDir, "parity.json"), &cell)
		loadDockerStats(filepath.Join(cellDir, "docker-stats.csv"), &cell)

		// Derived fields
		cell.TimingBroken = (classify.LatencyShape{
			HTTPReqs: cell.HTTPReqs,
			P50:      cell.HTTPReqDurationP50,
			P95:      cell.HTTPReqDurationP95,
			Max:      cell.HTTPReqDurationMax,
		}).IsTimingBroken()
		cell.Health = classify.Classify(
			classify.Counters{
				Policy2xx:           cell.Policy2xx,
				Policy4xxExpected:   cell.Policy4xxExpected,
				Policy4xxUnexpected: cell.Policy4xxUnexpected,
				Policy5xxUnexpected: cell.Policy5xxUnexpected,
			},
			classify.LatencyShape{
				HTTPReqs: cell.HTTPReqs,
				P50:      cell.HTTPReqDurationP50,
				P95:      cell.HTTPReqDurationP95,
				Max:      cell.HTTPReqDurationMax,
			},
			cell.Verdict == "EXCLUDED",
		)

		cells = append(cells, cell)
		return nil
	})
	if walkErr != nil {
		return nil, walkErr
	}

	// Stable canonical sort: gateway, policy, load, scenario
	sort.SliceStable(cells, func(i, j int) bool {
		if cells[i].Gateway != cells[j].Gateway {
			return cells[i].Gateway < cells[j].Gateway
		}
		if cells[i].Policy != cells[j].Policy {
			return cells[i].Policy < cells[j].Policy
		}
		if cells[i].Load != cells[j].Load {
			return cells[i].Load < cells[j].Load
		}
		return cells[i].Scenario < cells[j].Scenario
	})

	if len(cells) == 0 {
		return nil, fmt.Errorf("aggregate: no cells found under reports/%s/raw", a.RunID)
	}
	return cells, nil
}

// canonicalColumns mirrors scripts/aggregate-csv.sh § COLUMNS.
var canonicalColumns = []string{
	"gateway", "policy", "scenario", "load", "run_id", "verdict", "parity_status",
	"http_reqs", "http_req_rate", "iter_duration_avg_ms",
	"http_req_duration_p50", "http_req_duration_p90", "http_req_duration_p95",
	"http_req_duration_p99", "http_req_duration_max",
	"http_req_failed_rate",
	"policy_2xx", "policy_4xx_expected", "policy_4xx_unexpected", "policy_5xx_unexpected",
	"checks_total", "checks_passes", "checks_fails",
	"mem_rss_peak", "mem_rss_steady", "cpu_pct_peak", "cpu_pct_steady",
}

// WriteCSV writes the canonical 27-column wide CSV.
func (a *Aggregator) WriteCSV(path string, cells []Cell) error {
	f, err := openWrite(path)
	if err != nil {
		return err
	}
	defer f.Close()

	w := csv.NewWriter(f)
	defer w.Flush()
	if err := w.Write(canonicalColumns); err != nil {
		return err
	}
	for _, c := range cells {
		if err := w.Write(rowCSV(c)); err != nil {
			return err
		}
	}
	return w.Error()
}

// WriteJSONL writes one JSON object per line — superset of CSV with
// derived fields (Health, TimingBroken, OutputDirRel).
func (a *Aggregator) WriteJSONL(path string, cells []Cell) error {
	f, err := openWrite(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for _, c := range cells {
		if err := enc.Encode(c); err != nil {
			return err
		}
	}
	return nil
}

// WriteMarkdown emits a quick human-readable rollup. Useful for
// pasting into PR descriptions or reviewer notes.
func (a *Aggregator) WriteMarkdown(path string, cells []Cell) error {
	f, err := openWrite(path)
	if err != nil {
		return err
	}
	defer f.Close()

	header := "| gateway | policy | load | verdict | health | reqs | RPS | p50 ms | p95 ms | 5xx |"
	sep := "|---|---|---|---|---|---:|---:|---:|---:|---:|"
	if _, err := fmt.Fprintln(f, header); err != nil {
		return err
	}
	if _, err := fmt.Fprintln(f, sep); err != nil {
		return err
	}
	for _, c := range cells {
		p50 := "—"
		p95 := "—"
		if !c.TimingBroken {
			p50 = fmt.Sprintf("%.2f", c.HTTPReqDurationP50)
			p95 = fmt.Sprintf("%.2f", c.HTTPReqDurationP95)
		}
		if _, err := fmt.Fprintf(f, "| %s | %s | %s | %s | %s | %d | %.0f | %s | %s | %d |\n",
			c.Gateway, c.Policy, c.Load, c.Verdict, c.Health,
			c.HTTPReqs, c.HTTPReqRate, p50, p95, c.Policy5xxUnexpected,
		); err != nil {
			return err
		}
	}
	return nil
}

// -----------------------------------------------------------------------------
// k6-summary parsing — only the fields aggregate-csv.sh consumes.
// -----------------------------------------------------------------------------

// k6Summary uses RawMessage for root_group.checks so we can unmarshal
// it as either an array (older k6 versions) or an object keyed by
// check name (1.x). aggregate-csv.sh's jq pipeline papers over both
// shapes; we do the same explicitly.
type k6Summary struct {
	Metrics map[string]json.RawMessage `json:"metrics"`
	Root    struct {
		Checks json.RawMessage `json:"checks"`
	} `json:"root_group"`
}

type k6Check struct {
	Passes int64 `json:"passes"`
	Fails  int64 `json:"fails"`
}

func loadK6Summary(path string, cell *Cell) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var sum k6Summary
	if err := json.Unmarshal(data, &sum); err != nil {
		return err
	}

	cell.HTTPReqs = metricInt(sum.Metrics, "http_reqs", "count")
	cell.HTTPReqRate = metricFloat(sum.Metrics, "http_reqs", "rate")
	cell.IterDurationAvgMs = metricFloat(sum.Metrics, "iteration_duration", "avg")
	cell.HTTPReqDurationP50 = metricFloat(sum.Metrics, "http_req_duration", "p(50)")
	if cell.HTTPReqDurationP50 == 0 {
		cell.HTTPReqDurationP50 = metricFloat(sum.Metrics, "http_req_duration", "med")
	}
	cell.HTTPReqDurationP90 = metricFloat(sum.Metrics, "http_req_duration", "p(90)")
	cell.HTTPReqDurationP95 = metricFloat(sum.Metrics, "http_req_duration", "p(95)")
	cell.HTTPReqDurationP99 = metricFloat(sum.Metrics, "http_req_duration", "p(99)")
	cell.HTTPReqDurationMax = metricFloat(sum.Metrics, "http_req_duration", "max")
	cell.HTTPReqFailedRate = metricFloat(sum.Metrics, "http_req_failed", "value")
	cell.Policy2xx = metricInt(sum.Metrics, "policy_2xx", "count")
	cell.Policy4xxExpected = metricInt(sum.Metrics, "policy_4xx_expected", "count")
	cell.Policy4xxUnexpected = metricInt(sum.Metrics, "policy_4xx_unexpected", "count")
	cell.Policy5xxUnexpected = metricInt(sum.Metrics, "policy_5xx_unexpected", "count")

	if len(sum.Root.Checks) > 0 {
		var asMap map[string]k6Check
		if err := json.Unmarshal(sum.Root.Checks, &asMap); err == nil {
			for _, ch := range asMap {
				cell.ChecksTotal += ch.Passes + ch.Fails
				cell.ChecksPasses += ch.Passes
				cell.ChecksFails += ch.Fails
			}
		} else {
			var asArr []k6Check
			if err := json.Unmarshal(sum.Root.Checks, &asArr); err == nil {
				for _, ch := range asArr {
					cell.ChecksTotal += ch.Passes + ch.Fails
					cell.ChecksPasses += ch.Passes
					cell.ChecksFails += ch.Fails
				}
			}
		}
	}
	return nil
}

// loadExcluded reads the lightweight schema written when a gateway
// declares a feature missing.
func loadExcluded(path string, cell *Cell) {
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var p struct {
		Reason string `json:"reason"`
	}
	_ = json.Unmarshal(data, &p)
	if p.Reason != "" && cell.ParityStatus == "" {
		cell.ParityStatus = p.Reason
	}
}

func loadParity(path string, cell *Cell) {
	data, err := os.ReadFile(path)
	if err != nil {
		cell.ParityStatus = "UNKNOWN"
		return
	}
	var rep struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(data, &rep); err == nil && rep.Status != "" {
		cell.ParityStatus = rep.Status
	} else {
		cell.ParityStatus = "UNKNOWN"
	}
}

// -----------------------------------------------------------------------------
// docker-stats.csv rollup — same logic as aggregate-csv.sh's awk.
// CSV columns: time,cpu_ns_total,cpu_ns_system,cpu_online,rss_bytes,...
// -----------------------------------------------------------------------------

func loadDockerStats(path string, cell *Cell) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	rows, err := r.ReadAll()
	if err != nil || len(rows) < 3 {
		return
	}
	rows = rows[1:] // drop header

	var (
		rssPeak, rssSteady int64
		cpuPeak, cpuSteady float64
		rssSamples         []int64
		cpuSamples         []float64
		prevCPU            int64
		prevSys            int64
		online             int64
	)

	if v, err := strconv.ParseInt(strings.TrimSpace(rows[0][1]), 10, 64); err == nil {
		prevCPU = v
	}
	if v, err := strconv.ParseInt(strings.TrimSpace(rows[0][2]), 10, 64); err == nil {
		prevSys = v
	}
	if v, err := strconv.ParseInt(strings.TrimSpace(rows[0][3]), 10, 64); err == nil {
		online = v
	}

	for _, row := range rows[1:] {
		if len(row) < 5 {
			continue
		}
		cpuTot, _ := strconv.ParseInt(strings.TrimSpace(row[1]), 10, 64)
		sysTot, _ := strconv.ParseInt(strings.TrimSpace(row[2]), 10, 64)
		on, _ := strconv.ParseInt(strings.TrimSpace(row[3]), 10, 64)
		rss, _ := strconv.ParseInt(strings.TrimSpace(row[4]), 10, 64)
		if on > 0 {
			online = on
		}

		var cpuPct float64
		if sysTot-prevSys > 0 && online > 0 {
			cpuPct = float64(cpuTot-prevCPU) / float64(sysTot-prevSys) * float64(online) * 100.0
		}
		prevCPU = cpuTot
		prevSys = sysTot

		if rss > rssPeak {
			rssPeak = rss
		}
		if cpuPct > cpuPeak {
			cpuPeak = cpuPct
		}
		rssSamples = append(rssSamples, rss)
		cpuSamples = append(cpuSamples, cpuPct)
	}

	if n := len(rssSamples); n > 0 {
		half := n / 2
		rssTail := append([]int64(nil), rssSamples[half:]...)
		cpuTail := append([]float64(nil), cpuSamples[half:]...)
		sort.Slice(rssTail, func(i, j int) bool { return rssTail[i] < rssTail[j] })
		sort.Slice(cpuTail, func(i, j int) bool { return cpuTail[i] < cpuTail[j] })
		rssSteady = rssTail[len(rssTail)/2]
		cpuSteady = cpuTail[len(cpuTail)/2]
	}

	cell.MemRSSPeakBytes = rssPeak
	cell.MemRSSSteadyBytes = rssSteady
	cell.CPUPctPeak = roundTo(cpuPeak, 2)
	cell.CPUPctSteady = roundTo(cpuSteady, 2)
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// splitCellName parses "policy__load__scenario[__repN]" → (policy, load, scenario, ok).
func splitCellName(name string) (string, string, string, bool) {
	parts := strings.SplitN(name, "__", 3)
	if len(parts) != 3 {
		return "", "", "", false
	}
	policy := parts[0]
	load := parts[1]
	scenario := parts[2]
	// Strip optional __repN suffix from scenario
	if i := strings.Index(scenario, "__rep"); i >= 0 {
		scenario = scenario[:i]
	}
	return policy, load, scenario, true
}

func metricInt(metrics map[string]json.RawMessage, name, field string) int64 {
	raw, ok := metrics[name]
	if !ok {
		return 0
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return 0
	}
	v, ok := m[field]
	if !ok {
		return 0
	}
	var f float64
	if err := json.Unmarshal(v, &f); err != nil {
		return 0
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return int64(f)
}

func metricFloat(metrics map[string]json.RawMessage, name, field string) float64 {
	raw, ok := metrics[name]
	if !ok {
		return 0
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return 0
	}
	v, ok := m[field]
	if !ok {
		return 0
	}
	var f float64
	if err := json.Unmarshal(v, &f); err != nil {
		return 0
	}
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return f
}

func rowCSV(c Cell) []string {
	return []string{
		c.Gateway, c.Policy, c.Scenario, c.Load, c.RunID, c.Verdict, c.ParityStatus,
		fmt.Sprintf("%d", c.HTTPReqs),
		formatFloat(c.HTTPReqRate),
		formatFloat(c.IterDurationAvgMs),
		formatFloat(c.HTTPReqDurationP50),
		formatFloat(c.HTTPReqDurationP90),
		formatFloat(c.HTTPReqDurationP95),
		formatFloat(c.HTTPReqDurationP99),
		formatFloat(c.HTTPReqDurationMax),
		formatFloat(c.HTTPReqFailedRate),
		fmt.Sprintf("%d", c.Policy2xx),
		fmt.Sprintf("%d", c.Policy4xxExpected),
		fmt.Sprintf("%d", c.Policy4xxUnexpected),
		fmt.Sprintf("%d", c.Policy5xxUnexpected),
		fmt.Sprintf("%d", c.ChecksTotal),
		fmt.Sprintf("%d", c.ChecksPasses),
		fmt.Sprintf("%d", c.ChecksFails),
		fmt.Sprintf("%d", c.MemRSSPeakBytes),
		fmt.Sprintf("%d", c.MemRSSSteadyBytes),
		formatFloat(c.CPUPctPeak),
		formatFloat(c.CPUPctSteady),
	}
}

func formatFloat(f float64) string {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return "0"
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

func roundTo(v float64, places int) float64 {
	shift := math.Pow(10, float64(places))
	return math.Round(v*shift) / shift
}

func openWrite(path string) (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	return os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
}
