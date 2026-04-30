// Package readiness runs N readiness probes concurrently and waits
// for every probe to succeed (or for the per-probe timeout to elapse).
// It is the Go core behind the `bench aws-readiness` subcommand, which
// in turn replaces the nested for-loop in
// scripts/perf-aws-full-report.sh that used to wait for cloud-init +
// Docker on each cluster sequentially.
//
// The package is intentionally Probe-shape-agnostic. Probe.Run is a
// caller-supplied function returning nil on success — the AWS command
// wires it to a real ssh subprocess; tests wire it to a closure.
package readiness

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// Probe is one readiness check.
type Probe struct {
	// Label is a human-readable identifier surfaced in progress output
	// and Result entries (e.g. "cluster 0 loadgen").
	Label string

	// Run executes the readiness check once. It must return nil on
	// success and a descriptive error on failure. Run is invoked
	// repeatedly by Wait until it succeeds, the per-probe timeout
	// elapses, or the parent context is cancelled.
	Run func(ctx context.Context) error
}

// Result captures the outcome of one probe at the end of Wait.
type Result struct {
	Label    string
	Ready    bool
	Attempts int
	Duration time.Duration
	LastErr  error
}

// Snapshot is a point-in-time progress view passed to Config.Progress.
type Snapshot struct {
	Total   int
	Ready   int
	Waiting int
	Failed  int
	Elapsed time.Duration
}

// Config controls probe pacing and reporting. Zero values are
// replaced with sensible defaults (see Wait).
type Config struct {
	// PollInterval is the wait between attempts on the same probe.
	// Defaults to 10s.
	PollInterval time.Duration

	// Timeout is the per-probe wall-clock budget. After Timeout
	// elapses without a successful Run, the probe is marked failed
	// and Wait returns a non-nil error. Defaults to 15 minutes.
	Timeout time.Duration

	// MaxAttempts caps how many times a single probe will be
	// retried. 0 (default) means unlimited retries until Timeout
	// elapses — the right knob for liveness probes (cloud-init wait,
	// docker info). For one-shot operations (rsync / tarball
	// transfer) set MaxAttempts to a small value (typically 2: one
	// retry to absorb a network blip, but no more — every retry
	// re-uploads the same payload).
	MaxAttempts int

	// Concurrency caps how many probes run simultaneously. 0
	// (default) means one goroutine per probe — appropriate when
	// the probe itself is cheap (a single ssh round-trip). Set
	// Concurrency to a small number when probes consume
	// shared-resource budgets the operator's machine can saturate
	// (e.g. uplink bandwidth for tar-pipe-ssh).
	Concurrency int

	// Progress, when non-nil, is invoked on a ticker every
	// ProgressEvery (default = PollInterval) plus once at the very
	// end. Snapshots are constructed from atomic counters so the
	// callback never blocks probe goroutines.
	Progress func(s Snapshot)

	// ProgressEvery overrides the cadence of the Progress callback.
	// Zero falls back to PollInterval.
	ProgressEvery time.Duration
}

// Wait runs every probe in its own goroutine and returns once they
// all either succeeded or exhausted their per-probe Timeout. Results
// preserve the input order so callers can print a deterministic
// summary. The error is non-nil when at least one probe failed.
func Wait(ctx context.Context, probes []Probe, cfg Config) ([]Result, error) {
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = 10 * time.Second
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 15 * time.Minute
	}
	if cfg.ProgressEvery <= 0 {
		cfg.ProgressEvery = cfg.PollInterval
	}

	results := make([]Result, len(probes))
	for i := range probes {
		results[i].Label = probes[i].Label
	}

	var (
		ready   int64
		failed  int64
		mu      sync.Mutex // guards results[i] writes
		wg      sync.WaitGroup
		started = time.Now()
	)

	// Concurrency gate. A nil channel falls through every receive in
	// O(1), preserving the unlimited-fanout behaviour when
	// cfg.Concurrency is 0. A buffered channel of size N caps
	// in-flight probe goroutines to N — every probe acquires a slot
	// before calling probe.Run and releases it on completion.
	var sem chan struct{}
	if cfg.Concurrency > 0 {
		sem = make(chan struct{}, cfg.Concurrency)
	}

	for i, probe := range probes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if sem != nil {
				select {
				case sem <- struct{}{}:
				case <-ctx.Done():
					mu.Lock()
					results[i] = Result{Label: probe.Label, LastErr: ctx.Err()}
					mu.Unlock()
					atomic.AddInt64(&failed, 1)
					return
				}
				defer func() { <-sem }()
			}
			r := waitOne(ctx, probe, cfg, started)
			mu.Lock()
			results[i] = r
			mu.Unlock()
			if r.Ready {
				atomic.AddInt64(&ready, 1)
			} else {
				atomic.AddInt64(&failed, 1)
			}
		}()
	}

	// Progress ticker — runs alongside probes, exits cleanly when
	// they're all done.
	progressDone := make(chan struct{})
	if cfg.Progress != nil {
		go func() {
			ticker := time.NewTicker(cfg.ProgressEvery)
			defer ticker.Stop()
			for {
				select {
				case <-progressDone:
					return
				case <-ticker.C:
					cfg.Progress(snapshot(len(probes), &ready, &failed, started))
				}
			}
		}()
	}

	wg.Wait()
	close(progressDone)

	if cfg.Progress != nil {
		cfg.Progress(snapshot(len(probes), &ready, &failed, started))
	}

	failedCount := int(atomic.LoadInt64(&failed))
	if failedCount > 0 {
		return results, fmt.Errorf("%d/%d probes failed readiness", failedCount, len(probes))
	}
	return results, nil
}

func snapshot(total int, ready, failed *int64, started time.Time) Snapshot {
	r := int(atomic.LoadInt64(ready))
	f := int(atomic.LoadInt64(failed))
	return Snapshot{
		Total:   total,
		Ready:   r,
		Failed:  f,
		Waiting: total - r - f,
		Elapsed: time.Since(started),
	}
}

// waitOne polls a single probe until success, timeout or cancellation.
// All branch transitions go through the same `select` to guarantee a
// cancelled context aborts immediately even if the probe is mid-sleep.
func waitOne(ctx context.Context, probe Probe, cfg Config, started time.Time) Result {
	r := Result{Label: probe.Label}
	deadline := time.Now().Add(cfg.Timeout)

	for {
		// Check cancellation BEFORE the next attempt — saves one
		// pointless ssh round-trip when the operator hits Ctrl+C.
		select {
		case <-ctx.Done():
			r.Duration = time.Since(started)
			r.LastErr = errors.Join(ctx.Err(), r.LastErr)
			return r
		default:
		}

		if time.Now().After(deadline) {
			r.Duration = time.Since(started)
			if r.LastErr == nil {
				r.LastErr = fmt.Errorf("timeout after %s", cfg.Timeout)
			}
			return r
		}

		r.Attempts++
		err := probe.Run(ctx)
		if err == nil {
			r.Ready = true
			r.Duration = time.Since(started)
			return r
		}
		r.LastErr = err

		// Honour the retry cap before sleeping — no point waiting a
		// PollInterval just to fall through to the same exit path.
		if cfg.MaxAttempts > 0 && r.Attempts >= cfg.MaxAttempts {
			r.Duration = time.Since(started)
			return r
		}

		// Sleep PollInterval before the next attempt, but bail out on
		// ctx cancellation so the operator doesn't have to wait out a
		// full poll interval after Ctrl+C.
		timer := time.NewTimer(cfg.PollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
		case <-timer.C:
		}
	}
}
