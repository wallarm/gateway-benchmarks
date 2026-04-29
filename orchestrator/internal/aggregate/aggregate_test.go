package aggregate

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestSplitCellName(t *testing.T) {
	cases := []struct {
		in       string
		policy   string
		load     string
		scenario string
		ok       bool
	}{
		{"p01-vanilla__p1-baseline__s01-vanilla-http", "p01-vanilla", "p1-baseline", "s01-vanilla-http", true},
		{"p12-full-pipeline__p2-sustained__s12-full-pipeline-http",
			"p12-full-pipeline", "p2-sustained", "s12-full-pipeline-http", true},
		{"p01-vanilla__p1-baseline__s01-vanilla-http__rep3",
			"p01-vanilla", "p1-baseline", "s01-vanilla-http", true},
		{"not-a-cell", "", "", "", false},
		{"p01__bad", "", "", "", false},
	}
	for _, c := range cases {
		gotP, gotL, gotS, ok := splitCellName(c.in)
		if ok != c.ok {
			t.Errorf("splitCellName(%q): ok=%v, want %v", c.in, ok, c.ok)
			continue
		}
		if !c.ok {
			continue
		}
		if gotP != c.policy || gotL != c.load || gotS != c.scenario {
			t.Errorf("splitCellName(%q) = (%q,%q,%q), want (%q,%q,%q)",
				c.in, gotP, gotL, gotS, c.policy, c.load, c.scenario)
		}
	}
}

func TestFormatFloat(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "0"},
		{1.5, "1.5"},
		{math.NaN(), "0"},
		{math.Inf(1), "0"},
	}
	for _, c := range cases {
		if got := formatFloat(c.in); got != c.want {
			t.Errorf("formatFloat(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRoundTo(t *testing.T) {
	if got := roundTo(1.23456, 2); got != 1.23 {
		t.Errorf("roundTo(1.23456, 2) = %v, want 1.23", got)
	}
	if got := roundTo(1.235, 2); got != 1.24 {
		t.Errorf("roundTo(1.235, 2) = %v, want 1.24", got)
	}
}

// TestLoadDockerStats_Bandwidth asserts that the net/block rollups
// compute totals (last - first) and peak-bps (max delta bytes/sec
// between adjacent samples) off a canonical CSV — the same schema
// internal/stats.CSVHeader defines. Three baseline samples at 1s
// spacing with a bandwidth burst between samples 2 and 3:
//
//	t=0s   net_rx=100    net_tx=200
//	t=1s   net_rx=1_100  net_tx=2_200     (Δ=1_000 / Δ=2_000 → 1k / 2k bps)
//	t=3s   net_rx=11_100 net_tx=22_200    (Δ=10_000 / Δ=20_000, dt=2s → 5k / 10k bps)
func TestLoadDockerStats_Bandwidth(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker-stats.csv")
	csv := "" +
		"ts_utc,cpu_ns_total,cpu_ns_system,cpu_online,mem_bytes,mem_limit,net_rx_bytes,net_tx_bytes,blkio_read_bytes,blkio_write_bytes\n" +
		// Row 0 = baseline; loadDockerStats skips it for rate
		// calcs but takes its net counters as "firstNetRx".
		"2026-04-24T12:00:00Z,0,0,4,104857600,2147483648,100,200,10,20\n" +
		// Row 1 = +1s, Δrx=1000, Δtx=2000
		"2026-04-24T12:00:01Z,500000,10000000,4,104857600,2147483648,1100,2200,1010,2020\n" +
		// Row 2 = +2s, Δrx=10000, Δtx=20000 → dt=2s → 5000 / 10000 bps
		"2026-04-24T12:00:03Z,1500000,30000000,4,104857600,2147483648,11100,22200,11010,22020\n"
	if err := os.WriteFile(path, []byte(csv), 0o644); err != nil {
		t.Fatal(err)
	}

	var c Cell
	loadDockerStats(path, &c)

	if c.NetRxTotalBytes != 11_000 {
		t.Errorf("NetRxTotalBytes = %d, want 11000", c.NetRxTotalBytes)
	}
	if c.NetTxTotalBytes != 22_000 {
		t.Errorf("NetTxTotalBytes = %d, want 22000", c.NetTxTotalBytes)
	}
	if c.NetRxPeakBps != 5000 {
		t.Errorf("NetRxPeakBps = %v, want 5000", c.NetRxPeakBps)
	}
	if c.NetTxPeakBps != 10000 {
		t.Errorf("NetTxPeakBps = %v, want 10000", c.NetTxPeakBps)
	}
	if c.BlkReadTotalBytes != 11_000 || c.BlkWriteTotalBytes != 22_000 {
		t.Errorf("block totals = read %d write %d, want 11000/22000", c.BlkReadTotalBytes, c.BlkWriteTotalBytes)
	}
	if c.BlkReadPeakBps != 5000 || c.BlkWritePeakBps != 10000 {
		t.Errorf("block peaks = read %v write %v, want 5000/10000", c.BlkReadPeakBps, c.BlkWritePeakBps)
	}
	if c.MemLimitBytes != 2_147_483_648 {
		t.Errorf("MemLimitBytes = %d, want 2147483648", c.MemLimitBytes)
	}
	if c.MemRSSPeakBytes == 0 {
		t.Errorf("MemRSSPeakBytes = 0, want non-zero (regression: should not have broken existing code path)")
	}
	deriveResourceBottleneck(&c)
	if c.ResourceBottleneck == "" {
		t.Fatal("ResourceBottleneck should be derived")
	}
}

// TestLoadDockerStats_LegacySchema confirms backwards compatibility
// with pre-bandwidth CSVs (5 columns only). We should still populate
// mem/cpu fields and silently zero out the bandwidth columns.
func TestLoadDockerStats_LegacySchema(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "docker-stats.csv")
	csv := "" +
		"ts_utc,cpu_ns_total,cpu_ns_system,cpu_online,mem_bytes\n" +
		"2026-04-24T12:00:00Z,0,0,4,104857600\n" +
		"2026-04-24T12:00:01Z,500000,10000000,4,104857600\n" +
		"2026-04-24T12:00:02Z,1500000,30000000,4,209715200\n"
	if err := os.WriteFile(path, []byte(csv), 0o644); err != nil {
		t.Fatal(err)
	}

	var c Cell
	loadDockerStats(path, &c)
	if c.MemRSSPeakBytes != 209_715_200 {
		t.Errorf("MemRSSPeakBytes = %d, want 209715200", c.MemRSSPeakBytes)
	}
	if c.NetRxTotalBytes != 0 || c.NetTxTotalBytes != 0 {
		t.Errorf("bandwidth must default to zero on legacy schema, got rx=%d tx=%d",
			c.NetRxTotalBytes, c.NetTxTotalBytes)
	}
	if c.NetRxPeakBps != 0 || c.NetTxPeakBps != 0 {
		t.Errorf("bandwidth peak must default to zero, got rx=%v tx=%v",
			c.NetRxPeakBps, c.NetTxPeakBps)
	}
}

// TestCanonicalColumns_ContainsResourceColumns protects the CSV contract:
// resource pressure columns are appended after the legacy/bandwidth fields.
func TestCanonicalColumns_ContainsResourceColumns(t *testing.T) {
	if got := len(canonicalColumns); got != 40 {
		t.Errorf("canonicalColumns has %d entries, want 40", got)
	}
	tail := canonicalColumns[len(canonicalColumns)-6:]
	want := []string{
		"blk_read_total_bytes", "blk_write_total_bytes",
		"blk_read_peak_bps", "blk_write_peak_bps",
		"resource_bottleneck", "resource_bottleneck_detail",
	}
	for i, w := range want {
		if tail[i] != w {
			t.Errorf("canonicalColumns tail[%d] = %q, want %q", i, tail[i], w)
		}
	}
}
