// Package stats is the Go-native replacement for
// scripts/docker-stats-sidecar.sh. It polls the Docker Engine REST
// API (same endpoint, same raw-counter payload, same CSV schema) in a
// goroutine and writes one CSV row per interval to disk.
//
// Motivation — the shell sidecar worked but required bash + curl +
// jq on every host that runs a cell, added a second process to
// orchestrate (PID tracking, SIGTERM dance, wait/reap), and forced
// load-gateway.sh to fork-exec another shell. Porting it to Go lets
// `bench run` own the full sampling lifecycle: collector is a
// context-cancellable goroutine, artefacts land in the same
// reports/<run-id>/raw/<cell>/docker-stats.csv file the aggregator
// already consumes, and the only host dependency is Docker itself.
//
// CSV schema (unchanged from the shell script — the aggregator reads
// both outputs interchangeably):
//
//	ts_utc, cpu_ns_total, cpu_ns_system, cpu_online, mem_bytes,
//	mem_limit, net_rx_bytes, net_tx_bytes, blkio_read_bytes,
//	blkio_write_bytes
//
// All counters are cumulative (monotonic per-container); the
// aggregator computes deltas and peaks.
//
// Metrics sampled (same as the shell sidecar, plus explicit plumbing
// for the bandwidth columns that were already in the CSV but never
// read by the aggregator):
//
//   - CPU       — .cpu_stats.{cpu_usage.total_usage, system_cpu_usage,
//     online_cpus}
//   - Memory    — .memory_stats.{usage, limit}
//   - Network   — sum of .networks.*.{rx_bytes, tx_bytes}
//   - Block I/O — sum of .blkio_stats.io_service_bytes_recursive
//     entries split by op ∈ {read, write}
package stats

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Default CSV header — kept as a package-level var so tests can
// assert schema compatibility with scripts/docker-stats-sidecar.sh.
var csvHeader = []string{
	"ts_utc",
	"cpu_ns_total",
	"cpu_ns_system",
	"cpu_online",
	"mem_bytes",
	"mem_limit",
	"net_rx_bytes",
	"net_tx_bytes",
	"blkio_read_bytes",
	"blkio_write_bytes",
}

// Collector samples one container every Interval and writes one CSV
// row per sample. Zero-value config is invalid; use New to build.
type Collector struct {
	// Container is the docker container name or ID we sample.
	Container string

	// Output is the path of the CSV file we append to. Parent
	// directories are created on Start.
	Output string

	// Interval between samples. Defaults to 1s when zero.
	Interval time.Duration

	// Socket path for the Docker Engine unix socket. Empty = probe
	// $DOCKER_HOST_SOCK, then ~/.docker/run/docker.sock (macOS),
	// then /var/run/docker.sock (Linux).
	Socket string

	// StartupTimeout is the window in which the container must
	// appear on the Engine after Start returns. If it never shows
	// up, Start returns and the goroutine exits quietly — matches
	// the shell sidecar's "sleep 1, warn if dead" behaviour.
	// Zero defaults to 30s.
	StartupTimeout time.Duration

	// Logger receives non-fatal warnings (socket probe failure,
	// container not found, per-sample errors). nil = no logs.
	Logger func(format string, args ...any)
}

// Start launches the sampling goroutine and blocks only until the
// initial socket + container probe succeed (or fail permanently).
// The returned stop func waits for the goroutine to flush its last
// row and close the CSV file — call it either via defer or after
// ctx cancel when you need a barrier.
//
// If the Docker socket is reachable but the container never shows up
// within StartupTimeout, Start returns an error; no CSV is written.
// This mirrors scripts/docker-stats-sidecar.sh's exit-3 path.
func (c *Collector) Start(ctx context.Context) (stop func(), err error) {
	if c.Container == "" {
		return nil, errors.New("stats: Container is required")
	}
	if c.Output == "" {
		return nil, errors.New("stats: Output is required")
	}
	interval := c.Interval
	if interval <= 0 {
		interval = time.Second
	}
	startup := c.StartupTimeout
	if startup <= 0 {
		startup = 30 * time.Second
	}

	socket, err := c.resolveSocket()
	if err != nil {
		return nil, err
	}
	client := newUnixHTTPClient(socket, 3*time.Second)

	if err := pingEngine(ctx, client); err != nil {
		return nil, fmt.Errorf("stats: docker engine unreachable on %s: %w", socket, err)
	}

	containerID, err := waitForContainer(ctx, client, c.Container, startup)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(filepath.Dir(c.Output), 0o755); err != nil {
		return nil, fmt.Errorf("stats: mkdir %s: %w", filepath.Dir(c.Output), err)
	}

	// Append mode + write header only when the file is new — lets
	// concurrent shell and Go collectors share a file safely in the
	// degenerate case (not a supported flow, but won't clobber).
	needHeader := !fileExistsNonEmpty(c.Output)
	f, err := os.OpenFile(c.Output, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("stats: open %s: %w", c.Output, err)
	}
	w := csv.NewWriter(f)
	if needHeader {
		if err := w.Write(csvHeader); err != nil {
			_ = f.Close()
			return nil, fmt.Errorf("stats: write header: %w", err)
		}
		w.Flush()
	}

	done := make(chan struct{})
	loopCtx, cancelLoop := context.WithCancel(ctx)

	go func() {
		defer close(done)
		defer func() {
			w.Flush()
			_ = f.Close()
		}()

		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		// Take the first sample immediately so the CSV has at
		// least one baseline row even on sub-second shutdowns.
		c.sampleOnce(loopCtx, client, containerID, w)

		for {
			select {
			case <-loopCtx.Done():
				return
			case <-ticker.C:
				c.sampleOnce(loopCtx, client, containerID, w)
			}
		}
	}()

	stop = func() {
		cancelLoop()
		<-done
	}
	return stop, nil
}

// sampleOnce reads one /stats payload and appends one CSV row. On
// any transport/parse error we log and skip — mirroring the shell
// sidecar's "zero-row runs == container not running this second"
// tolerance. We never return an error from here; a single hiccup
// shouldn't take the whole cell down.
func (c *Collector) sampleOnce(ctx context.Context, client *http.Client, containerID string, w *csv.Writer) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://localhost/containers/"+containerID+"/stats?stream=false", nil)
	resp, err := client.Do(req)
	if err != nil {
		if ctx.Err() == nil {
			c.logf("stats: sample transport error: %v", err)
		}
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// 404 = container gone (race with compose down); common
		// on graceful shutdown — log only at high verbosity.
		return
	}

	var raw containerStatsPayload
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		c.logf("stats: decode: %v", err)
		return
	}

	row := rowFor(time.Now().UTC(), raw)
	if err := w.Write(row); err != nil {
		c.logf("stats: csv write: %v", err)
		return
	}
	w.Flush()
}

// logf is a no-op when Logger is nil.
func (c *Collector) logf(format string, args ...any) {
	if c.Logger != nil {
		c.Logger(format, args...)
	}
}

// -----------------------------------------------------------------------------
// Docker Engine plumbing — kept minimal (no external SDK). All we need
// is unix-socket HTTP + one JSON decode. The extra ~100 lines here are
// cheaper than pulling in moby/moby and its transitive dep tree.
// -----------------------------------------------------------------------------

func (c *Collector) resolveSocket() (string, error) {
	if c.Socket != "" {
		return c.Socket, nil
	}
	if envSock := os.Getenv("DOCKER_HOST_SOCK"); envSock != "" {
		return envSock, nil
	}
	candidates := []string{}
	if home, _ := os.UserHomeDir(); home != "" {
		candidates = append(candidates, filepath.Join(home, ".docker", "run", "docker.sock"))
	}
	candidates = append(candidates, "/var/run/docker.sock")
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && (st.Mode()&os.ModeSocket) != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("stats: no docker socket found (tried DOCKER_HOST_SOCK and %v)", candidates)
}

func newUnixHTTPClient(socketPath string, timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", socketPath)
			},
			DisableKeepAlives: false,
			MaxIdleConns:      2,
			IdleConnTimeout:   30 * time.Second,
		},
	}
}

func pingEngine(ctx context.Context, client *http.Client) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/_ping", nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("engine ping returned %d", resp.StatusCode)
	}
	return nil
}

// waitForContainer resolves the container name to an ID, retrying
// with a short backoff until StartupTimeout expires. This replaces
// the shell sidecar's one-shot probe — the Go collector is started
// from the orchestrator BEFORE `docker compose up` finishes, so it
// needs to tolerate a brief "not yet" window.
func waitForContainer(ctx context.Context, client *http.Client, name string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if id, err := inspectContainerID(ctx, client, name); err == nil && id != "" {
			return id, nil
		} else {
			lastErr = err
		}
		if time.Now().After(deadline) {
			if lastErr == nil {
				lastErr = fmt.Errorf("container %q not found after %s", name, timeout)
			}
			return "", fmt.Errorf("stats: %w", lastErr)
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
}

func inspectContainerID(ctx context.Context, client *http.Client, name string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"http://localhost/containers/"+name+"/json", nil)
	if err != nil {
		return "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return "", nil // not yet — retry
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("inspect %q: status %d", name, resp.StatusCode)
	}
	var out struct {
		ID string `json:"Id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	return out.ID, nil
}

// -----------------------------------------------------------------------------
// Stats payload — the subset of /containers/<id>/stats we care about.
// -----------------------------------------------------------------------------

type containerStatsPayload struct {
	CPUStats struct {
		CPUUsage struct {
			TotalUsage int64 `json:"total_usage"`
		} `json:"cpu_usage"`
		SystemCPUUsage int64 `json:"system_cpu_usage"`
		OnlineCPUs     int64 `json:"online_cpus"`
	} `json:"cpu_stats"`
	MemoryStats struct {
		Usage int64 `json:"usage"`
		Limit int64 `json:"limit"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RxBytes int64 `json:"rx_bytes"`
		TxBytes int64 `json:"tx_bytes"`
	} `json:"networks"`
	BlkioStats struct {
		IOServiceBytesRecursive []struct {
			Op    string `json:"op"`
			Value int64  `json:"value"`
		} `json:"io_service_bytes_recursive"`
	} `json:"blkio_stats"`
}

func rowFor(ts time.Time, p containerStatsPayload) []string {
	var netRx, netTx int64
	for _, n := range p.Networks {
		netRx += n.RxBytes
		netTx += n.TxBytes
	}
	var blkRead, blkWrite int64
	for _, e := range p.BlkioStats.IOServiceBytesRecursive {
		switch strings.ToLower(e.Op) {
		case "read":
			blkRead += e.Value
		case "write":
			blkWrite += e.Value
		}
	}
	return []string{
		ts.Format("2006-01-02T15:04:05Z"),
		strconv.FormatInt(p.CPUStats.CPUUsage.TotalUsage, 10),
		strconv.FormatInt(p.CPUStats.SystemCPUUsage, 10),
		strconv.FormatInt(p.CPUStats.OnlineCPUs, 10),
		strconv.FormatInt(p.MemoryStats.Usage, 10),
		strconv.FormatInt(p.MemoryStats.Limit, 10),
		strconv.FormatInt(netRx, 10),
		strconv.FormatInt(netTx, 10),
		strconv.FormatInt(blkRead, 10),
		strconv.FormatInt(blkWrite, 10),
	}
}

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------

func fileExistsNonEmpty(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return st.Size() > 0
}

// CSVHeader exposes the canonical column list — used by the
// aggregator tests to assert schema parity with the shell sidecar.
func CSVHeader() []string {
	out := make([]string, len(csvHeader))
	copy(out, csvHeader)
	return out
}
