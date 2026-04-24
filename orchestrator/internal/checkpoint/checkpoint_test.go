package checkpoint

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/matrix"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/runner"
)

func TestRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "checkpoint.jsonl")

	cp, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer cp.Close()

	cell := matrix.Cell{Gateway: "nginx", Policy: "p01-vanilla", Scenario: "s01-vanilla-http", Load: "p1-baseline", Repetition: 1}
	res := runner.Result{
		Cell:      cell,
		Verdict:   runner.VerdictPass,
		Duration:  3.14,
		StartedAt: time.Now().UTC(),
		EndedAt:   time.Now().UTC(),
	}
	if err := cp.Append(res); err != nil {
		t.Fatal(err)
	}
	if v, ok := cp.HasDone(cell.ID()); !ok || v != runner.VerdictPass {
		t.Errorf("HasDone after Append: ok=%v v=%s", ok, v)
	}

	// reopen → should re-read previous state
	if err := cp.Close(); err != nil {
		t.Fatal(err)
	}
	cp2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer cp2.Close()
	if v, ok := cp2.HasDone(cell.ID()); !ok || v != runner.VerdictPass {
		t.Errorf("HasDone after reopen: ok=%v v=%s", ok, v)
	}
}

func TestOpenCreatesParents(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "deeper", "checkpoint.jsonl")
	cp, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	cp.Close()
	if _, err := os.Stat(path); err != nil {
		t.Errorf("checkpoint file not created: %v", err)
	}
}
