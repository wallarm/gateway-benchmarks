package readiness

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"
	"time"
)

// fastProbe returns a Probe that succeeds on attempt #succeedOn (1-
// indexed). Useful for asserting attempt counters and pacing.
func fastProbe(label string, succeedOn int) Probe {
	var attempts int64
	return Probe{
		Label: label,
		Run: func(_ context.Context) error {
			n := int(atomic.AddInt64(&attempts, 1))
			if n >= succeedOn {
				return nil
			}
			return errors.New("not ready yet")
		},
	}
}

// neverProbe always fails — used to drive the timeout / failure paths.
func neverProbe(label string) Probe {
	return Probe{
		Label: label,
		Run: func(_ context.Context) error {
			return errors.New("forever pending")
		},
	}
}

func TestWaitAllReadyImmediately(t *testing.T) {
	probes := []Probe{fastProbe("a", 1), fastProbe("b", 1), fastProbe("c", 1)}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: 10 * time.Millisecond,
		Timeout:      time.Second,
	})
	if err != nil {
		t.Fatalf("Wait: unexpected error %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("results: want 3, got %d", len(results))
	}
	for _, r := range results {
		if !r.Ready {
			t.Errorf("%s: want Ready, got LastErr=%v", r.Label, r.LastErr)
		}
		if r.Attempts != 1 {
			t.Errorf("%s: want 1 attempt, got %d", r.Label, r.Attempts)
		}
	}
}

func TestWaitRetriesUntilSuccess(t *testing.T) {
	// Succeed on attempt 3 — verify the loop polls more than once.
	probes := []Probe{fastProbe("slow", 3)}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: 5 * time.Millisecond,
		Timeout:      time.Second,
	})
	if err != nil {
		t.Fatalf("Wait: unexpected error %v", err)
	}
	if !results[0].Ready {
		t.Fatalf("expected Ready, got %+v", results[0])
	}
	if results[0].Attempts != 3 {
		t.Errorf("attempts: want 3, got %d", results[0].Attempts)
	}
}

func TestWaitTimeoutMarksProbeFailed(t *testing.T) {
	probes := []Probe{neverProbe("nope")}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: 5 * time.Millisecond,
		Timeout:      30 * time.Millisecond,
	})
	if err == nil {
		t.Fatalf("expected non-nil error after timeout")
	}
	if results[0].Ready {
		t.Fatalf("expected probe NOT ready: %+v", results[0])
	}
	if results[0].LastErr == nil {
		t.Fatalf("expected LastErr to be set")
	}
	if results[0].Attempts < 2 {
		t.Errorf("expected ≥2 attempts before timeout, got %d", results[0].Attempts)
	}
}

func TestWaitMixedOutcomes(t *testing.T) {
	// Two ready, one stuck — Wait must still finish (not block on the
	// failing probe forever) and report partial success in the error.
	probes := []Probe{
		fastProbe("ok-1", 1),
		neverProbe("stuck"),
		fastProbe("ok-2", 2),
	}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: 5 * time.Millisecond,
		Timeout:      30 * time.Millisecond,
	})
	if err == nil {
		t.Fatalf("expected error since one probe never succeeded")
	}
	readyCount := 0
	for _, r := range results {
		if r.Ready {
			readyCount++
		}
	}
	if readyCount != 2 {
		t.Errorf("ready count: want 2, got %d (results: %+v)", readyCount, results)
	}
}

func TestWaitContextCancellationStopsImmediately(t *testing.T) {
	probes := []Probe{neverProbe("a"), neverProbe("b")}
	ctx, cancel := context.WithCancel(context.Background())

	// Cancel after a short delay; Wait must return promptly.
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	results, err := Wait(ctx, probes, Config{
		PollInterval: 5 * time.Millisecond,
		Timeout:      10 * time.Second, // long, should NOT be reached
	})
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected non-nil error after cancellation")
	}
	if elapsed > 500*time.Millisecond {
		t.Errorf("Wait took %s after cancel; expected near-immediate return", elapsed)
	}
	for _, r := range results {
		if r.Ready {
			t.Errorf("%s: should not be ready under cancellation", r.Label)
		}
	}
}

func TestWaitProgressCallbackInvoked(t *testing.T) {
	// Fire a slow probe to give the progress ticker time to tick at
	// least once before everything completes.
	probes := []Probe{fastProbe("slowish", 4)}
	var snaps int64
	_, err := Wait(context.Background(), probes, Config{
		PollInterval:  10 * time.Millisecond,
		Timeout:       time.Second,
		ProgressEvery: 5 * time.Millisecond,
		Progress: func(s Snapshot) {
			atomic.AddInt64(&snaps, 1)
			// Sanity: counters are non-negative and consistent.
			if s.Total != 1 || s.Ready+s.Waiting+s.Failed != s.Total {
				t.Errorf("inconsistent snapshot: %+v", s)
			}
		},
	})
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if atomic.LoadInt64(&snaps) < 2 {
		t.Errorf("expected ≥2 progress snapshots (ticker + final), got %d", snaps)
	}
}

func TestWaitMaxAttemptsCapsRetries(t *testing.T) {
	// MaxAttempts=3 means a permanently-failing probe should give up
	// after exactly three attempts — not chew through the whole
	// timeout budget. PollInterval is tiny so the exit can only come
	// from the cap, not the timeout.
	probes := []Probe{neverProbe("capped")}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: time.Millisecond,
		Timeout:      10 * time.Second, // intentionally generous
		MaxAttempts:  3,
	})
	if err == nil {
		t.Fatalf("expected non-nil error after MaxAttempts exhausted")
	}
	if results[0].Attempts != 3 {
		t.Errorf("attempts: want exactly 3, got %d", results[0].Attempts)
	}
	if results[0].Ready {
		t.Errorf("probe should be marked not-ready after retry cap")
	}
}

func TestWaitMaxAttemptsAllowsSuccessBeforeCap(t *testing.T) {
	// MaxAttempts is a ceiling, not a floor — succeed-on-2 with cap=3
	// must still succeed on attempt 2.
	probes := []Probe{fastProbe("slowish", 2)}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: time.Millisecond,
		Timeout:      time.Second,
		MaxAttempts:  3,
	})
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if !results[0].Ready || results[0].Attempts != 2 {
		t.Errorf("want Ready after 2 attempts, got %+v", results[0])
	}
}

func TestWaitConcurrencyLimitsParallelism(t *testing.T) {
	// Twelve simultaneously-runnable probes with Concurrency=4 must
	// have ≤4 in flight at any moment. We measure this by counting
	// peak concurrent Run calls inside the probe closure.
	const total = 12
	const cap = 4
	var inFlight int64
	var peak int64
	var probes []Probe
	for i := range total {
		probes = append(probes, Probe{
			Label: fmt.Sprintf("p%d", i),
			Run: func(_ context.Context) error {
				cur := atomic.AddInt64(&inFlight, 1)
				defer atomic.AddInt64(&inFlight, -1)
				// Track the peak concurrent counter (compare-and-swap
				// loop avoids torn reads under heavy parallelism).
				for {
					old := atomic.LoadInt64(&peak)
					if cur <= old || atomic.CompareAndSwapInt64(&peak, old, cur) {
						break
					}
				}
				// Hold the slot long enough for all goroutines to be
				// scheduled and queued behind the semaphore.
				time.Sleep(20 * time.Millisecond)
				return nil
			},
		})
	}
	_, err := Wait(context.Background(), probes, Config{
		PollInterval: time.Millisecond,
		Timeout:      time.Second,
		Concurrency:  cap,
	})
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	got := atomic.LoadInt64(&peak)
	if got > int64(cap) {
		t.Errorf("peak concurrent probes: want ≤%d, got %d", cap, got)
	}
	if got < 2 {
		t.Errorf("peak concurrent probes: want some parallelism, got %d", got)
	}
}

func TestWaitPreservesInputOrder(t *testing.T) {
	probes := []Probe{
		fastProbe("first", 1),
		fastProbe("second", 1),
		fastProbe("third", 1),
	}
	results, err := Wait(context.Background(), probes, Config{
		PollInterval: 5 * time.Millisecond,
		Timeout:      time.Second,
	})
	if err != nil {
		t.Fatalf("Wait: %v", err)
	}
	want := []string{"first", "second", "third"}
	for i, r := range results {
		if r.Label != want[i] {
			t.Errorf("results[%d].Label: want %q, got %q", i, want[i], r.Label)
		}
	}
}
