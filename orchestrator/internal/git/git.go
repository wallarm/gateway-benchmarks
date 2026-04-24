// Package git is a thin wrapper around `git` that captures just the
// two facts the orchestrator needs at runtime: the current HEAD SHA and
// whether the working tree has uncommitted modifications.
//
// Used by internal/manifest to stamp every run with the exact source
// revision that produced it. A dirty tree is reported but does NOT
// abort the run — reviewers may still want to bench an unsaved patch
// against canonical numbers, the manifest just makes the deviation
// auditable.
package git

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Info captures the parts of git state that we stamp into manifests.
type Info struct {
	SHA     string `json:"sha"`     // 40-char hex; empty when not in a git tree
	Dirty   bool   `json:"dirty"`   // working tree has modifications
	Branch  string `json:"branch"`  // best-effort; empty in detached HEAD
	Remote  string `json:"remote"`  // best-effort; default-branch upstream URL
	HasGit  bool   `json:"has_git"` // false → not a git tree (e.g. tarball)
	Comment string `json:"comment,omitempty"`
}

// Probe queries git in `dir` and returns the captured Info. Never
// returns nil; on any failure the returned Info has HasGit=false and
// .Comment set to the underlying error so manifests stay self-describing.
func Probe(ctx context.Context, dir string) Info {
	if _, err := exec.LookPath("git"); err != nil {
		return Info{Comment: "git binary not on PATH"}
	}
	if !isGitTree(ctx, dir) {
		return Info{Comment: "not a git working tree"}
	}

	info := Info{HasGit: true}
	if sha, err := run(ctx, dir, "rev-parse", "HEAD"); err == nil {
		info.SHA = strings.TrimSpace(sha)
	} else {
		info.Comment = fmt.Sprintf("rev-parse HEAD failed: %v", err)
		return info
	}
	if out, err := run(ctx, dir, "status", "--porcelain"); err == nil {
		info.Dirty = strings.TrimSpace(out) != ""
	}
	if branch, err := run(ctx, dir, "rev-parse", "--abbrev-ref", "HEAD"); err == nil {
		b := strings.TrimSpace(branch)
		if b != "HEAD" {
			info.Branch = b
		}
	}
	if remote, err := run(ctx, dir, "config", "--get", "remote.origin.url"); err == nil {
		info.Remote = strings.TrimSpace(remote)
	}
	return info
}

// ShortSHA returns the first 7 hex chars (or "unknown" when empty).
func (i Info) ShortSHA() string {
	if i.SHA == "" {
		return "unknown"
	}
	if len(i.SHA) >= 7 {
		return i.SHA[:7]
	}
	return i.SHA
}

func isGitTree(ctx context.Context, dir string) bool {
	out, err := run(ctx, dir, "rev-parse", "--is-inside-work-tree")
	if err != nil {
		return false
	}
	return strings.TrimSpace(out) == "true"
}

func run(ctx context.Context, dir string, args ...string) (string, error) {
	if ctx == nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr)))
		}
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}
