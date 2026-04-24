package report

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/aggregate"
)

// Manifest is the read-only projection of reports/<id>/manifest.json
// the renderer consumes. We only carry the fields we surface in the
// hero / footer / downloads section — additional manifest fields stay
// untouched on disk.
type Manifest struct {
	SchemaVersion string         `json:"schema_version"`
	RunID         string         `json:"run_id"`
	Mode          string         `json:"mode"`
	StartedAt     string         `json:"started_at"`
	FinishedAt    string         `json:"finished_at"`
	DurationSec   float64        `json:"duration_sec"`
	Bench         BenchInfo      `json:"bench"`
	Git           GitInfo        `json:"git"`
	Host          HostInfo       `json:"host"`
	K6            K6Info         `json:"k6"`
	Gateways      []GatewayRef   `json:"gateways"`
	Seed          int64          `json:"seed"`
	Repetitions   int            `json:"repetitions"`
	StopOnFail    bool           `json:"stop_on_fail"`
	SelectedRows  []string       `json:"selected_rows"`
	Notes         string         `json:"notes,omitempty"`
}

// BenchInfo mirrors orchestrator/internal/manifest.BenchInfo.
type BenchInfo struct {
	Version   string `json:"version"`
	GitSHA    string `json:"git_sha"`
	GitDirty  bool   `json:"git_dirty"`
	BuildTime string `json:"build_time"`
	GoVersion string `json:"go_version"`
}

// GitInfo mirrors orchestrator/internal/git.Info.
type GitInfo struct {
	SHA    string `json:"sha"`
	Dirty  bool   `json:"dirty"`
	Branch string `json:"branch"`
	Remote string `json:"remote"`
	HasGit bool   `json:"has_git"`
}

// HostInfo carries os/arch/cpu/hostname stamped at run-time.
type HostInfo struct {
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	NumCPU   int    `json:"num_cpu"`
	Hostname string `json:"hostname"`
	Kernel   string `json:"kernel,omitempty"`
}

// K6Info pins the loadgen image.
type K6Info struct {
	Image  string `json:"image"`
	Digest string `json:"digest"`
}

// GatewayRef is one (gateway, image, digest) triple.
type GatewayRef struct {
	Name        string `json:"name"`
	Image       string `json:"image"`
	Digest      string `json:"digest,omitempty"`
	Source      string `json:"source,omitempty"`
	ComposePath string `json:"compose_path,omitempty"`
}

// LoadOptions controls how the renderer pulls data off disk.
//
//	RepoRoot       absolute path to the repo root (where reports/ lives)
//	RunID          single-run mode (preferred); reads
//	               reports/<RunID>/{cells.jsonl,manifest.json}
//	CombinedRunIDs multi-run mode; merges every listed run's cells.jsonl.
//	               When set, manifest is loaded from the first run that
//	               has one, and per-cell run_id is preserved.
//	JSONLOverride  bypass everything and read this exact path
//	ManifestPath   override manifest path (when JSONLOverride is set)
type LoadOptions struct {
	RepoRoot       string
	RunID          string
	CombinedRunIDs []string
	JSONLOverride  string
	ManifestPath   string
}

// Loaded carries everything the renderer needs in one place.
type Loaded struct {
	Cells    []aggregate.Cell
	Manifest *Manifest
	RunDir   string // canonical directory for relative download links
	RunIDs   []string
}

// Load reads the per-cell records (and, when present, the manifest)
// off disk. cells.jsonl is required; the manifest is optional but
// emits a warning when missing.
func Load(opts LoadOptions) (*Loaded, error) {
	switch {
	case opts.JSONLOverride != "":
		return loadFromExplicitPath(opts)
	case len(opts.CombinedRunIDs) > 0:
		return loadCombined(opts)
	case opts.RunID != "":
		return loadFromRunID(opts)
	default:
		return nil, errors.New("report: one of --run-id, --combined or --input is required")
	}
}

func loadFromExplicitPath(opts LoadOptions) (*Loaded, error) {
	cells, err := readJSONL(opts.JSONLOverride)
	if err != nil {
		return nil, fmt.Errorf("read cells: %w", err)
	}
	if len(cells) == 0 {
		return nil, fmt.Errorf("no cells in %s", opts.JSONLOverride)
	}
	loaded := &Loaded{
		Cells:  cells,
		RunDir: filepath.Dir(opts.JSONLOverride),
	}
	if opts.ManifestPath != "" {
		if mf, err := readManifest(opts.ManifestPath); err == nil {
			loaded.Manifest = mf
		}
	}
	loaded.RunIDs = uniqueRunIDs(cells)
	return loaded, nil
}

func loadFromRunID(opts LoadOptions) (*Loaded, error) {
	if opts.RepoRoot == "" {
		return nil, errors.New("repo-root is required when using --run-id")
	}
	runDir := filepath.Join(opts.RepoRoot, "reports", opts.RunID)
	cellsPath := filepath.Join(runDir, "cells.jsonl")
	cells, err := readJSONL(cellsPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", cellsPath, err)
	}
	if len(cells) == 0 {
		return nil, fmt.Errorf("no cells in %s", cellsPath)
	}

	loaded := &Loaded{
		Cells:  cells,
		RunDir: runDir,
	}
	if mf, err := readManifest(filepath.Join(runDir, "manifest.json")); err == nil {
		loaded.Manifest = mf
	}
	loaded.RunIDs = uniqueRunIDs(cells)
	return loaded, nil
}

func loadCombined(opts LoadOptions) (*Loaded, error) {
	if opts.RepoRoot == "" {
		return nil, errors.New("repo-root is required when using --combined")
	}
	loaded := &Loaded{}
	seen := map[string]struct{}{}
	for _, runID := range opts.CombinedRunIDs {
		runDir := filepath.Join(opts.RepoRoot, "reports", runID)
		cellsPath := filepath.Join(runDir, "cells.jsonl")
		cells, err := readJSONL(cellsPath)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", cellsPath, err)
		}
		loaded.Cells = append(loaded.Cells, cells...)
		seen[runID] = struct{}{}
		if loaded.Manifest == nil {
			if mf, err := readManifest(filepath.Join(runDir, "manifest.json")); err == nil {
				loaded.Manifest = mf
				loaded.RunDir = runDir
			}
		}
	}
	if len(loaded.Cells) == 0 {
		return nil, fmt.Errorf("combined load: no cells across %d runs", len(opts.CombinedRunIDs))
	}
	if loaded.RunDir == "" {
		// no manifest anywhere — anchor downloads at the first run dir
		loaded.RunDir = filepath.Join(opts.RepoRoot, "reports", opts.CombinedRunIDs[0])
	}
	loaded.RunIDs = uniqueRunIDs(loaded.Cells)
	return loaded, nil
}

func readJSONL(path string) ([]aggregate.Cell, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var cells []aggregate.Cell
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "//") || strings.HasPrefix(line, "#") {
			continue
		}
		var c aggregate.Cell
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			return nil, fmt.Errorf("decode %s: %w", path, err)
		}
		cells = append(cells, c)
	}
	if err := scanner.Err(); err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	return cells, nil
}

func readManifest(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var mf Manifest
	if err := json.Unmarshal(data, &mf); err != nil {
		return nil, fmt.Errorf("decode manifest %s: %w", path, err)
	}
	return &mf, nil
}

func uniqueRunIDs(cells []aggregate.Cell) []string {
	seen := map[string]struct{}{}
	for _, c := range cells {
		if c.RunID == "" {
			continue
		}
		seen[c.RunID] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for r := range seen {
		out = append(out, r)
	}
	sort.Strings(out)
	return out
}
