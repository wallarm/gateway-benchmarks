package cmd

import (
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
)

type progressTracker struct {
	out      io.Writer
	cells    []matrix.Cell
	expected []time.Duration
	interval time.Duration
	started  time.Time

	mu                sync.Mutex
	completed         int
	completedExpected time.Duration
	completedActual   time.Duration
}

func newProgressTracker(out io.Writer, cells []matrix.Cell, interval time.Duration) *progressTracker {
	if interval <= 0 {
		interval = 30 * time.Second
	}
	expected := make([]time.Duration, len(cells))
	for i, cell := range cells {
		expected[i] = expectedCellDuration(cell)
	}
	return &progressTracker{
		out:      out,
		cells:    cells,
		expected: expected,
		interval: interval,
		started:  time.Now(),
	}
}

func (p *progressTracker) PrintPlan() {
	fmt.Fprintf(p.out, "  progress: %d cells, estimated %s at current profile durations\n",
		len(p.cells), shortDuration(p.totalExpected()))
}

func (p *progressTracker) StartCell(index int, cell matrix.Cell) func() {
	started := time.Now()
	p.printCellLine("start", index, cell, 0)

	done := make(chan struct{})
	var once sync.Once
	go func() {
		ticker := time.NewTicker(p.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				p.printCellLine("running", index, cell, time.Since(started))
			case <-done:
				return
			}
		}
	}()

	return func() {
		once.Do(func() { close(done) })
	}
}

func (p *progressTracker) FinishCell(index int, cell matrix.Cell, actual time.Duration, verdict string) {
	if actual < 0 {
		actual = 0
	}
	p.mu.Lock()
	p.completed++
	if index >= 0 && index < len(p.expected) {
		p.completedExpected += p.expected[index]
	}
	p.completedActual += actual
	done := p.completed
	total := len(p.cells)
	eta := p.etaLocked(index+1, 0)
	elapsed := time.Since(p.started)
	p.mu.Unlock()

	fmt.Fprintf(p.out, "  progress: %s %d/%d done | elapsed %s | eta %s | last %s (%s)\n",
		progressBar(done, total, 24), done, total, shortDuration(elapsed),
		shortDuration(eta), verdict, shortDuration(actual))
}

func (p *progressTracker) printCellLine(state string, index int, cell matrix.Cell, currentElapsed time.Duration) {
	p.mu.Lock()
	done := p.completed
	total := len(p.cells)
	eta := p.etaLocked(index, currentElapsed)
	elapsed := time.Since(p.started)
	p.mu.Unlock()

	fmt.Fprintf(p.out, "  progress: %s %d/%d %s | current %s | elapsed %s | eta %s | %s\n",
		progressBar(done, total, 24), done, total, state,
		shortDuration(currentElapsed), shortDuration(elapsed), shortDuration(eta),
		formatCellLabel(cell))
}

func (p *progressTracker) etaLocked(currentIndex int, currentElapsed time.Duration) time.Duration {
	if currentIndex >= len(p.expected) {
		return 0
	}

	var remainingExpected time.Duration
	for i := currentIndex; i < len(p.expected); i++ {
		remainingExpected += p.expected[i]
	}
	if currentIndex >= 0 && currentIndex < len(p.expected) && currentElapsed > 0 {
		remainingExpected -= minDuration(currentElapsed, p.expected[currentIndex])
	}

	scale := 1.0
	if p.completedExpected > 0 && p.completedActual > 0 {
		scale = float64(p.completedActual) / float64(p.completedExpected)
		if scale < 0.25 {
			scale = 0.25
		}
		if scale > 4.0 {
			scale = 4.0
		}
	}
	return time.Duration(float64(remainingExpected) * scale)
}

func (p *progressTracker) totalExpected() time.Duration {
	var total time.Duration
	for _, d := range p.expected {
		total += d
	}
	return total
}

func expectedCellDuration(cell matrix.Cell) time.Duration {
	// The load profile dominates runtime; add a small fixed allowance
	// for parity, compose startup/teardown, aggregation artefacts, and
	// cold container checks. ETA self-corrects with actual completed cells.
	const overhead = 30 * time.Second
	switch cell.Load {
	case "p1-baseline", "p1c-paced":
		return 60*time.Second + overhead
	case "p2-sustained", "p2c-paced":
		return 5*time.Minute + overhead
	case "p3-ramp":
		return 8*time.Minute + overhead
	case "p3c-paced":
		return 7*time.Minute + overhead
	case "p4-stress", "p4c-paced":
		return 2*time.Minute + overhead
	default:
		return 2*time.Minute + overhead
	}
}

func progressBar(done, total, width int) string {
	if total <= 0 {
		return "[" + strings.Repeat("-", width) + "]"
	}
	if done < 0 {
		done = 0
	}
	if done > total {
		done = total
	}
	filled := int(float64(done) / float64(total) * float64(width))
	if filled > width {
		filled = width
	}
	return "[" + strings.Repeat("#", filled) + strings.Repeat("-", width-filled) + "]"
}

func shortDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	d = d.Round(time.Second)
	h := int(d / time.Hour)
	d -= time.Duration(h) * time.Hour
	m := int(d / time.Minute)
	d -= time.Duration(m) * time.Minute
	s := int(d / time.Second)
	if h > 0 {
		return fmt.Sprintf("%dh%02dm", h, m)
	}
	if m > 0 {
		return fmt.Sprintf("%dm%02ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
