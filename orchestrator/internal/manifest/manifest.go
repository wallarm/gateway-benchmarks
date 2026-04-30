// Package manifest assembles the per-run manifest.json that pins
// every dimension of a benchmark cycle (source revision, image
// digests, seeds, infra mode, host info, selected matrix). The
// goal is reproducibility: a reviewer holding manifest.json should
// be able to recreate the exact same run and obtain comparable
// numbers.
//
// The schema is intentionally human-readable JSON — readers can
// inspect it without a Go decoder.
package manifest

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/git"
	"github.com/wallarm/gateway-benchmarks/orchestrator/internal/version"
)

// Manifest is the full run manifest. JSON tags use snake_case to match
// the rest of the report assets (matrix.csv, k6 summaries).
type Manifest struct {
	SchemaVersion string    `json:"schema_version"`
	RunID         string    `json:"run_id"`
	Mode          string    `json:"mode"` // "local" | "aws"
	StartedAt     time.Time `json:"started_at"`
	FinishedAt    time.Time `json:"finished_at,omitempty"`
	DurationSec   float64   `json:"duration_sec,omitempty"`

	Bench    BenchInfo    `json:"bench"`
	Git      git.Info     `json:"git"`
	Host     HostInfo     `json:"host"`
	K6       K6Info       `json:"k6"`
	Gateways []GatewayRef `json:"gateways"`

	Seed         int64    `json:"seed"`
	Repetitions  int      `json:"repetitions"`
	StopOnFail   bool     `json:"stop_on_fail"`
	SelectedRows []string `json:"selected_rows"` // human-readable cell ids

	Notes string `json:"notes,omitempty"`
}

// BenchInfo records the orchestrator binary itself.
type BenchInfo struct {
	Version   string `json:"version"`
	GitSHA    string `json:"git_sha"`
	GitDirty  bool   `json:"git_dirty"`
	BuildTime string `json:"build_time"`
	GoVersion string `json:"go_version"`
}

// HostInfo records the loadgen host that drives the matrix. On AWS
// runs this is the loadgen EC2; on local runs it's the operator's
// machine.
type HostInfo struct {
	OS       string `json:"os"`
	Arch     string `json:"arch"`
	NumCPU   int    `json:"num_cpu"`
	Hostname string `json:"hostname"`
	Kernel   string `json:"kernel,omitempty"`
}

// K6Info records the pinned grafana/k6 image with sha256 digest. The
// orchestrator does not invoke k6 directly — it goes through
// scripts/load-gateway.sh — but we still record the image we expect
// the script to use so reviewers can audit it.
type K6Info struct {
	Image  string `json:"image"`
	Digest string `json:"digest,omitempty"`
}

// GatewayRef records the docker image (or build context) for a single
// gateway included in the run. The Digest field is best-effort — we
// pull `docker images --no-trunc --format {{.Digest}}` after the
// gateway is up; for source-built gateways (Wallarm) we record the
// build context instead.
type GatewayRef struct {
	Name        string `json:"name"`
	Image       string `json:"image,omitempty"`
	Digest      string `json:"digest,omitempty"`
	Source      string `json:"source,omitempty"`       // e.g. "built from src", "registry"
	ComposePath string `json:"compose_path,omitempty"` // gateways/<name>/docker-compose.yaml
}

// Builder accumulates fields incrementally during a run.
type Builder struct {
	repoRoot string
	m        Manifest
}

// New creates a fresh Builder seeded with the orchestrator's own
// build info, host info, and a probed git state.
func New(ctx context.Context, repoRoot, mode, runID string, seed int64) *Builder {
	hostname, _ := os.Hostname()
	dirty := version.GitDirty == "true"
	return &Builder{
		repoRoot: repoRoot,
		m: Manifest{
			SchemaVersion: "1",
			RunID:         runID,
			Mode:          mode,
			StartedAt:     time.Now().UTC(),
			Bench: BenchInfo{
				Version:   version.Version,
				GitSHA:    version.GitSHA,
				GitDirty:  dirty,
				BuildTime: version.BuildTime,
				GoVersion: runtime.Version(),
			},
			Git: git.Probe(ctx, repoRoot),
			Host: HostInfo{
				OS:       runtime.GOOS,
				Arch:     runtime.GOARCH,
				NumCPU:   runtime.NumCPU(),
				Hostname: hostname,
				Kernel:   probeKernel(ctx),
			},
			K6:       probeK6(ctx),
			Seed:     seed,
			Gateways: []GatewayRef{},
		},
	}
}

// AddGateway records a gateway reference. Call after the gateway has
// been brought up so we can resolve its image digest.
func (b *Builder) AddGateway(ctx context.Context, name string) {
	composePath := filepath.Join(b.repoRoot, "gateways", name, "docker-compose.yaml")
	ref := GatewayRef{
		Name:        name,
		ComposePath: composePath,
	}
	if image, digest, ok := probeGatewayImage(ctx, name); ok {
		ref.Image = image
		ref.Digest = digest
		ref.Source = "registry"
	} else {
		ref.Source = "compose-resolved-or-built-from-src"
	}
	b.m.Gateways = append(b.m.Gateways, ref)
}

// AddRow appends a "<gateway>/<policy>/<load>/<scenario>" identifier.
func (b *Builder) AddRow(id string) {
	b.m.SelectedRows = append(b.m.SelectedRows, id)
}

// SetRepetitions and SetStopOnFail mirror the run-level CLI flags.
func (b *Builder) SetRepetitions(n int)    { b.m.Repetitions = n }
func (b *Builder) SetStopOnFail(stop bool) { b.m.StopOnFail = stop }
func (b *Builder) SetNotes(notes string)   { b.m.Notes = notes }

// Finalize stamps the end time and computed duration.
func (b *Builder) Finalize() {
	now := time.Now().UTC()
	b.m.FinishedAt = now
	b.m.DurationSec = now.Sub(b.m.StartedAt).Seconds()
}

// Snapshot returns a copy suitable for logging.
func (b *Builder) Snapshot() Manifest { return b.m }

// Write serialises the manifest as pretty-printed JSON to `path`.
// Any parent directories are created on demand.
func (b *Builder) Write(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir manifest dir: %w", err)
	}
	data, err := json.MarshalIndent(b.m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		return fmt.Errorf("write manifest: %w", err)
	}
	return nil
}

// -----------------------------------------------------------------------------
// Probes
// -----------------------------------------------------------------------------

func probeKernel(ctx context.Context) string {
	if _, err := exec.LookPath("uname"); err != nil {
		return ""
	}
	out, err := exec.CommandContext(ctx, "uname", "-rsm").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// probeK6 resolves the grafana/k6 reference used by scripts/load-gateway.sh.
// We only care about reproducibility — pulling a fresh digest is the
// caller's job. Default mirrors scripts/load-gateway.sh § K6_IMAGE.
func probeK6(_ context.Context) K6Info {
	const defaultK6 = "grafana/k6:1.7.1@sha256:4fd3a694926b064d3491d9b02b01cde886583c4931f1223816e3d9a7bdfa7e0f"
	img := os.Getenv("K6_IMAGE")
	if img == "" {
		img = defaultK6
	}
	digest := ""
	if i := strings.Index(img, "@"); i >= 0 {
		digest = img[i+1:]
	}
	return K6Info{Image: img, Digest: digest}
}

// probeGatewayImage runs `docker compose config --images gateway` and
// resolves the digest for the gateway service. The earlier
// implementation called `--images` without a service filter and took
// `lines[0]`, which on every multi-service stack returned the
// `backend` image instead of the gateway under test (the run
// aws-20260429T151344Z manifest had wallarm/traefik/kong all listed
// as gateway-benchmarks/backend:v2.22.1). Best effort — returns
// ok=false on any error so the caller can fall back to "built from
// src".
func probeGatewayImage(ctx context.Context, gateway string) (image, digest string, ok bool) {
	composePath := filepath.Join("gateways", gateway, "docker-compose.yaml")
	if _, err := os.Stat(composePath); err != nil {
		return "", "", false
	}
	out, err := exec.CommandContext(ctx, "docker", "compose", "-f", composePath, "config", "--images", "gateway").Output()
	if err != nil {
		return "", "", false
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return "", "", false
	}
	image = lines[0]
	digOut, err := exec.CommandContext(ctx, "docker", "image", "inspect",
		"--format", "{{index .RepoDigests 0}}", image).Output()
	if err == nil {
		dig := strings.TrimSpace(string(digOut))
		if i := strings.Index(dig, "@"); i >= 0 {
			digest = dig[i+1:]
		}
	}
	return image, digest, true
}
