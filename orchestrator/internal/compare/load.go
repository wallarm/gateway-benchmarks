package compare

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// LoadOptions steers Load for one side of the comparison.
type LoadOptions struct {
	RepoRoot string
	// One of RunID / JSONLPath wins (JSONLPath trumps RunID).
	RunID         string
	JSONLPath     string
	ManifestPath  string // optional override; defaults to reports/<RunID>/manifest.json
	Label         string // passed straight through into Input.Label
	AllowMissing  bool   // if true, missing manifest is not an error
}

// Load resolves cells.jsonl + manifest.json for a single run and
// wraps them in an Input ready for Compare.
func Load(opts LoadOptions) (Input, error) {
	if opts.RunID == "" && opts.JSONLPath == "" {
		return Input{}, errors.New("compare.Load: either RunID or JSONLPath must be set")
	}

	jsonl := opts.JSONLPath
	if jsonl == "" {
		jsonl = filepath.Join(opts.RepoRoot, "reports", opts.RunID, "cells.jsonl")
	}

	cells, err := loadJSONL(jsonl)
	if err != nil {
		return Input{}, fmt.Errorf("read %s: %w", jsonl, err)
	}

	manifestPath := opts.ManifestPath
	if manifestPath == "" && opts.RunID != "" {
		manifestPath = filepath.Join(opts.RepoRoot, "reports", opts.RunID, "manifest.json")
	}
	mv, merr := loadManifest(manifestPath)
	if merr != nil && !errors.Is(merr, fs.ErrNotExist) {
		return Input{}, fmt.Errorf("read %s: %w", manifestPath, merr)
	}

	label := opts.Label
	if label == "" {
		label = opts.RunID
	}
	return Input{Label: label, Cells: cells, Manifest: mv}, nil
}

func loadJSONL(path string) ([]aggregate.Cell, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	var out []aggregate.Cell
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		var c aggregate.Cell
		if err := json.Unmarshal(line, &c); err != nil {
			return nil, fmt.Errorf("decode cells.jsonl: %w", err)
		}
		out = append(out, c)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

func loadManifest(path string) (*ManifestView, error) {
	if path == "" {
		return nil, fs.ErrNotExist
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var mv ManifestView
	if err := json.Unmarshal(b, &mv); err != nil {
		return nil, fmt.Errorf("decode manifest: %w", err)
	}
	return &mv, nil
}
