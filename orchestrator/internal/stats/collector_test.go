package stats

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// fakeEngine spins up a tiny http.Server on a unix socket that
// mimics the three endpoints the collector talks to:
//
//	GET /_ping                          → 200 OK "OK"
//	GET /containers/<name>/json         → 200 OK {"Id": "<sha>"} or 404
//	GET /containers/<id>/stats?stream=false → 200 OK containerStatsPayload
//
// Tests can inject per-sample counters via an atomic ticker so we
// can assert the CSV reflects monotonic growth.
type fakeEngine struct {
	socket      string
	server      *http.Server
	lis         net.Listener
	containerID string
	// sampleCount is bumped on every /stats call; its value is used
	// to synthesize monotonically increasing CPU / memory / network
	// counters, so CSV rows written out have a deterministic shape
	// the test can assert on.
	sampleCount atomic.Int64

	// initialMisses = number of consecutive 404s on /containers/.../json
	// before we start serving the id — lets us test waitForContainer's
	// retry loop.
	initialMisses atomic.Int32
}

func newFakeEngine(t *testing.T, containerName string) *fakeEngine {
	t.Helper()
	dir := t.TempDir()
	sock := filepath.Join(dir, "docker.sock")
	lis, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	f := &fakeEngine{
		socket:      sock,
		lis:         lis,
		containerID: "sha256:abcdef0123456789",
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/_ping", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte("OK"))
	})
	mux.HandleFunc("/containers/", func(w http.ResponseWriter, r *http.Request) {
		// /containers/<key>/json  or  /containers/<key>/stats
		parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/containers/"), "/")
		if len(parts) < 2 {
			http.NotFound(w, r)
			return
		}
		key, verb := parts[0], parts[1]
		switch verb {
		case "json":
			if key != containerName && key != f.containerID {
				http.NotFound(w, r)
				return
			}
			if f.initialMisses.Load() > 0 {
				f.initialMisses.Add(-1)
				http.NotFound(w, r)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]string{"Id": f.containerID})
		case "stats":
			if key != f.containerID && key != containerName {
				http.NotFound(w, r)
				return
			}
			n := f.sampleCount.Add(1)
			w.Header().Set("Content-Type", "application/json")
			// Counter fixtures — all monotonic, all touch every
			// aggregated column so rowFor can be asserted.
			payload := map[string]any{
				"cpu_stats": map[string]any{
					"cpu_usage": map[string]any{"total_usage": n * 1_000_000},
					"system_cpu_usage": n * 10_000_000,
					"online_cpus":      4,
				},
				"memory_stats": map[string]any{
					"usage": 100*1024*1024 + n*1024, // ~100 MiB + 1 KiB/step
					"limit": 2 * 1024 * 1024 * 1024,
				},
				"networks": map[string]any{
					"eth0": map[string]any{
						"rx_bytes": n * 1024,
						"tx_bytes": n * 2048,
					},
					// second interface to prove we sum across them
					"eth1": map[string]any{
						"rx_bytes": n * 512,
						"tx_bytes": n * 512,
					},
				},
				"blkio_stats": map[string]any{
					"io_service_bytes_recursive": []map[string]any{
						{"op": "Read", "value": n * 4096},
						{"op": "Write", "value": n * 8192},
						{"op": "Sync", "value": n * 100}, // not aggregated
					},
				},
			}
			_ = json.NewEncoder(w).Encode(payload)
		default:
			http.NotFound(w, r)
		}
	})

	f.server = &http.Server{Handler: mux, ReadHeaderTimeout: 2 * time.Second}
	go func() { _ = f.server.Serve(lis) }()
	t.Cleanup(func() {
		_ = f.server.Close()
	})
	return f
}

func TestCollector_EndToEnd(t *testing.T) {
	eng := newFakeEngine(t, "gwb-nginx")

	out := filepath.Join(t.TempDir(), "docker-stats.csv")
	c := &Collector{
		Container:      "gwb-nginx",
		Output:         out,
		Interval:       50 * time.Millisecond,
		Socket:         eng.socket,
		StartupTimeout: 2 * time.Second,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	stop, err := c.Start(ctx)
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	// Let it tick a few times, then cut it off.
	time.Sleep(275 * time.Millisecond)
	stop()

	// At least 3 rows (baseline + ticks); the baseline sample is
	// taken before the first ticker fire.
	rows := readCSV(t, out)
	if len(rows) < 4 { // header + 3 data rows minimum
		t.Fatalf("expected >=4 rows, got %d: %v", len(rows), rows)
	}
	if got, want := rows[0], CSVHeader(); !stringSliceEqual(got, want) {
		t.Errorf("header mismatch: got %v, want %v", got, want)
	}

	// First data row: cpu_ns_total should be 1_000_000 (sample #1).
	first := rows[1]
	if first[1] != "1000000" {
		t.Errorf("row 1 cpu_ns_total = %q, want 1000000", first[1])
	}
	// net_rx_bytes for sample N should be N*1024 + N*512 = N*1536.
	if first[6] != "1536" {
		t.Errorf("row 1 net_rx_bytes = %q, want 1536 (sum of two interfaces)", first[6])
	}
	// blkio_read_bytes = N*4096; write = N*8192; sync op must be dropped.
	if first[8] != "4096" {
		t.Errorf("row 1 blkio_read_bytes = %q, want 4096", first[8])
	}
	if first[9] != "8192" {
		t.Errorf("row 1 blkio_write_bytes = %q, want 8192", first[9])
	}

	// Monotonic growth on net/cpu across rows.
	for i := 2; i < len(rows); i++ {
		prev, cur := rows[i-1], rows[i]
		if !numericGE(cur[1], prev[1]) {
			t.Errorf("cpu_ns_total regressed row %d: %s → %s", i, prev[1], cur[1])
		}
		if !numericGE(cur[6], prev[6]) {
			t.Errorf("net_rx_bytes regressed row %d: %s → %s", i, prev[6], cur[6])
		}
	}
}

func TestCollector_WaitsForContainer(t *testing.T) {
	eng := newFakeEngine(t, "gwb-later")
	eng.initialMisses.Store(3) // 3x 404 before json starts serving

	out := filepath.Join(t.TempDir(), "docker-stats.csv")
	c := &Collector{
		Container:      "gwb-later",
		Output:         out,
		Interval:       50 * time.Millisecond,
		Socket:         eng.socket,
		StartupTimeout: 3 * time.Second,
	}
	stop, err := c.Start(context.Background())
	if err != nil {
		t.Fatalf("Start tolerated missing container poorly: %v", err)
	}
	time.Sleep(120 * time.Millisecond)
	stop()

	rows := readCSV(t, out)
	if len(rows) < 2 {
		t.Fatalf("expected at least header + 1 sample, got %v", rows)
	}
}

func TestCollector_FailsIfContainerNeverAppears(t *testing.T) {
	eng := newFakeEngine(t, "never-there")
	eng.initialMisses.Store(1_000_000) // permanently 404

	out := filepath.Join(t.TempDir(), "docker-stats.csv")
	c := &Collector{
		Container:      "never-there",
		Output:         out,
		Interval:       50 * time.Millisecond,
		Socket:         eng.socket,
		StartupTimeout: 150 * time.Millisecond,
	}
	_, err := c.Start(context.Background())
	if err == nil {
		t.Fatal("Start should fail when StartupTimeout elapses")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Errorf("error should mention not-found, got %v", err)
	}
	// No CSV should exist — we never opened one if Start errored.
	if _, err := os.Stat(out); err == nil {
		t.Errorf("unexpected CSV at %s after failed Start", out)
	}
}

func TestCollector_MissingSocket(t *testing.T) {
	c := &Collector{
		Container: "anything",
		Output:    filepath.Join(t.TempDir(), "x.csv"),
		Socket:    "/nonexistent/docker.sock",
	}
	_, err := c.Start(context.Background())
	if err == nil {
		t.Fatal("expected error for bogus socket")
	}
}

func TestCollector_RequiredFields(t *testing.T) {
	cases := []struct {
		name string
		c    Collector
	}{
		{"missing container", Collector{Output: "x"}},
		{"missing output", Collector{Container: "x"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := tc.c.Start(context.Background()); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func TestRowFor_Schema(t *testing.T) {
	ts := time.Date(2026, 4, 24, 12, 0, 0, 0, time.UTC)
	p := containerStatsPayload{}
	p.CPUStats.CPUUsage.TotalUsage = 123
	p.CPUStats.SystemCPUUsage = 456
	p.CPUStats.OnlineCPUs = 8
	p.MemoryStats.Usage = 789
	p.MemoryStats.Limit = 1000
	p.Networks = map[string]struct {
		RxBytes int64 `json:"rx_bytes"`
		TxBytes int64 `json:"tx_bytes"`
	}{
		"eth0": {RxBytes: 10, TxBytes: 20},
	}
	p.BlkioStats.IOServiceBytesRecursive = []struct {
		Op    string `json:"op"`
		Value int64  `json:"value"`
	}{
		{Op: "read", Value: 1},
		{Op: "WRITE", Value: 2},
		{Op: "discard", Value: 99},
	}
	row := rowFor(ts, p)
	want := []string{
		"2026-04-24T12:00:00Z", "123", "456", "8",
		"789", "1000", "10", "20", "1", "2",
	}
	if !stringSliceEqual(row, want) {
		t.Errorf("rowFor mismatch:\n got  %v\n want %v", row, want)
	}
	if len(row) != len(csvHeader) {
		t.Errorf("row has %d fields, header has %d", len(row), len(csvHeader))
	}
}

// -----------------------------------------------------------------------------
// Helpers — kept tiny so the test file is self-contained.
// -----------------------------------------------------------------------------

func readCSV(t *testing.T, path string) [][]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open csv: %v", err)
	}
	defer f.Close()
	rows, err := csv.NewReader(f).ReadAll()
	if err != nil {
		t.Fatalf("read csv: %v", err)
	}
	return rows
}

func stringSliceEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func numericGE(a, b string) bool {
	var av, bv int64
	_, _ = fmt.Sscan(a, &av)
	_, _ = fmt.Sscan(b, &bv)
	return av >= bv
}
