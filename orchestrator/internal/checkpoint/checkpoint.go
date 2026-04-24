// Package checkpoint persists per-cell completion records so an
// interrupted sweep can resume without re-running cells that already
// have an artefact on disk.
//
// The file format is JSONL — one runner.Result per line, appended
// atomically after each cell completes (PASS, EXCLUDED, FAIL,
// CRASHED or TIMEOUT). On resume we replay the file and skip any
// cell whose ID() is already present.
//
// We deliberately do NOT try to be clever about partial cells —
// if the orchestrator died mid-cell, the cell directory is left
// in whatever state load-gateway.sh's trap cleanup made of it,
// and the resume will simply re-attempt it.
package checkpoint

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/runner"
)

// File is an append-only checkpoint backed by a JSONL file on disk.
// All Append/Done calls are safe for concurrent use.
type File struct {
	path string

	mu   sync.Mutex
	seen map[string]runner.Verdict
	f    *os.File
}

// Open opens or creates the checkpoint file at path. Existing entries
// are loaded into the in-memory "seen" set so HasDone returns true
// for resumed cells.
func Open(path string) (*File, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("checkpoint mkdir: %w", err)
	}

	cp := &File{
		path: path,
		seen: make(map[string]runner.Verdict),
	}

	if err := cp.load(); err != nil {
		return nil, err
	}

	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("checkpoint open: %w", err)
	}
	cp.f = f
	return cp, nil
}

// Close flushes and closes the underlying file.
func (c *File) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.f == nil {
		return nil
	}
	err := c.f.Close()
	c.f = nil
	return err
}

// Append records the result of one cell. The on-disk file is
// fsync'd so a power-cut between cells doesn't lose progress.
func (c *File) Append(res runner.Result) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	data, err := json.Marshal(res)
	if err != nil {
		return fmt.Errorf("checkpoint marshal: %w", err)
	}
	if _, err := c.f.Write(append(data, '\n')); err != nil {
		return fmt.Errorf("checkpoint write: %w", err)
	}
	if err := c.f.Sync(); err != nil {
		return fmt.Errorf("checkpoint fsync: %w", err)
	}
	c.seen[res.Cell.ID()] = res.Verdict
	return nil
}

// HasDone reports whether the given cell ID was previously recorded
// with a terminal verdict (PASS/EXCLUDED/FAIL/CRASHED/TIMEOUT).
func (c *File) HasDone(id string) (runner.Verdict, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	v, ok := c.seen[id]
	return v, ok
}

// Snapshot returns a copy of the seen-set for diagnostics / banners.
func (c *File) Snapshot() map[string]runner.Verdict {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]runner.Verdict, len(c.seen))
	for k, v := range c.seen {
		out[k] = v
	}
	return out
}

func (c *File) load() error {
	f, err := os.Open(c.path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("checkpoint load: %w", err)
	}
	defer f.Close()

	r := bufio.NewReader(f)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			var res runner.Result
			if jerr := json.Unmarshal(line, &res); jerr == nil && res.Cell.Gateway != "" {
				c.seen[res.Cell.ID()] = res.Verdict
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("checkpoint read: %w", err)
		}
	}
}
