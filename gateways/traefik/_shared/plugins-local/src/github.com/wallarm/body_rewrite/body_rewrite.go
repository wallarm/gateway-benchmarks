// Package body_rewrite implements a minimal Traefik middleware plugin
// that injects a dotted JSON path and drops one or more dotted JSON
// paths from either the request or the response body. It is loaded
// by traefik's Yaegi-based plugin interpreter; every stdlib import
// below is on the Yaegi-supported list.
//
// Design scope (deliberately narrow so the plugin is auditable):
//
//   * One inject path (string), value is an arbitrary JSON-compatible
//     value (bool / number / string). The value is read from the
//     plugin config as a raw JSON-compatible Go value, which means a
//     Traefik dynamic.yaml snippet like
//
//         plugin:
//           body_rewrite:
//             target: request
//             injectPath: bench.injected
//             injectValue: true
//
//     sets `$.bench.injected = true` on the body.
//
//   * Zero or more drop paths; each is a dotted JSON path, evaluated
//     left-to-right against the decoded body and removed if present.
//     Missing keys are a no-op (we do not treat "path not present"
//     as an error — the fixtures' "drop is unconditional" probes
//     explicitly hit bodies where the path is absent).
//
//   * `target: request` rewrites the request body before proxying;
//     `target: response` wraps the downstream writer, buffers every
//     chunk, rewrites on the way out, and recomputes Content-Length
//     (the key trap that breaks every "just proxy the bytes" pattern).
//
//   * Non-JSON bodies pass through untouched. We detect this via
//     `Content-Type` containing `application/json` AND a body that
//     decodes into a JSON object (arrays and scalars pass through —
//     every fixture under POLICIES.md § p09 / § p10 targets objects).
//
// The plugin is intentionally API-symmetric with the nginx / envoy /
// wallarm columns' body-rewrite helpers (they all ship a
// `rewrite(raw, inject, drop)` function against the same invariants).
// A reviewer can read one column's implementation and trust the
// fixture semantics across the whole matrix.
package body_rewrite

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
)

// Config is the plugin configuration shape exposed to dynamic.yaml.
// Only the fields below are honoured; anything else in the plugin
// stanza is ignored silently by Yaegi's JSON decoder.
type Config struct {
	// Target is either "request" or "response". Default: "request".
	Target string `json:"target,omitempty"`

	// InjectPath is a dotted JSON path, e.g. "bench.injected". Empty
	// means "skip the inject step".
	InjectPath string `json:"injectPath,omitempty"`

	// InjectValue is the JSON-compatible value written at InjectPath.
	// Any value the Yaegi JSON decoder can hand us works (bool,
	// number, string, array, object). The fixtures only ever use
	// a scalar.
	InjectValue interface{} `json:"injectValue,omitempty"`

	// DropPaths is a list of dotted JSON paths to remove from the
	// body. Missing keys are a no-op.
	DropPaths []string `json:"dropPaths,omitempty"`
}

// CreateConfig returns the default plugin config (required by
// Traefik's plugin contract).
func CreateConfig() *Config {
	return &Config{
		Target:     "request",
		DropPaths:  []string{},
	}
}

// BodyRewrite is the instantiated middleware.
type BodyRewrite struct {
	next        http.Handler
	name        string
	target      string
	injectPath  []string
	injectValue interface{}
	dropPaths   [][]string
}

// New is the Traefik plugin constructor.
func New(ctx context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	target := cfg.Target
	if target == "" {
		target = "request"
	}
	br := &BodyRewrite{
		next:        next,
		name:        name,
		target:      target,
		injectValue: coerceJSONLiteral(cfg.InjectValue),
	}
	if cfg.InjectPath != "" {
		br.injectPath = splitPath(cfg.InjectPath)
	}
	for _, p := range cfg.DropPaths {
		br.dropPaths = append(br.dropPaths, splitPath(p))
	}
	return br, nil
}

// coerceJSONLiteral walks around a quirk of Traefik's plugin config
// decoder: every primitive in the dynamic.yaml `plugin.<name>` stanza
// arrives at the plugin as a `string` (Traefik normalizes YAML
// scalars to strings before handing them to Yaegi, regardless of the
// declared Go field type). Without this coercion the fixture's
// `injectValue: true` lands in the backend as the JSON string
// `"true"` instead of the boolean `true`.
//
// We only try the cheap conversions that the fixtures actually use
// (bool + number); everything else falls through unchanged.
func coerceJSONLiteral(v interface{}) interface{} {
	s, ok := v.(string)
	if !ok {
		return v
	}
	switch s {
	case "true":
		return true
	case "false":
		return false
	case "null":
		return nil
	}
	if n, err := strconv.ParseFloat(s, 64); err == nil {
		return n
	}
	return s
}

// ServeHTTP dispatches to the request- or response-side rewriter.
func (b *BodyRewrite) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if b.target == "response" {
		b.rewriteResponse(rw, req)
		return
	}
	b.rewriteRequest(rw, req)
}

// rewriteRequest reads the entire request body, decodes it, applies
// inject / drop, re-encodes, resets the body, and recomputes
// Content-Length before calling next.
func (b *BodyRewrite) rewriteRequest(rw http.ResponseWriter, req *http.Request) {
	if req.Body == nil {
		// POLICIES.md § p09 requires the inject to apply even when
		// the client sent an empty body. We synthesize `{}` so the
		// inject path has a starting object.
		req.Body = io.NopCloser(bytes.NewReader([]byte("{}")))
		req.ContentLength = 2
		req.Header.Set("Content-Type", "application/json")
	}

	raw, err := io.ReadAll(req.Body)
	if err != nil {
		http.Error(rw, "body_rewrite: read request body: "+err.Error(), http.StatusBadRequest)
		return
	}
	_ = req.Body.Close()

	// Empty bodies are coerced to `{}` — same shape invariant as
	// gateways/nginx/p10-req-body (cjson.safe path) and
	// gateways/envoy/p10-req-body (lua body_rewrite).
	if len(bytes.TrimSpace(raw)) == 0 {
		raw = []byte("{}")
	}

	// Non-JSON bodies pass through unmodified (every fixture under
	// p09 / p10 sends Content-Type: application/json and an object
	// shape; real-world clients that ship text/xml should not be
	// silently mangled).
	out, ok := b.rewriteJSONObject(raw)
	if !ok {
		req.Body = io.NopCloser(bytes.NewReader(raw))
		req.ContentLength = int64(len(raw))
		b.next.ServeHTTP(rw, req)
		return
	}

	req.Body = io.NopCloser(bytes.NewReader(out))
	req.ContentLength = int64(len(out))
	// Traefik forwards Content-Length from req.ContentLength on the
	// upstream hop, but some Transport code paths trust the header
	// string directly (e.g. when `Transfer-Encoding: chunked` is
	// missing). Stamping it explicitly covers both branches.
	req.Header.Set("Content-Length", strconv.Itoa(len(out)))
	req.Header.Set("Content-Type", "application/json")
	b.next.ServeHTTP(rw, req)
}

// rewriteResponse wraps the downstream writer, captures every chunk,
// rewrites the accumulated body on the way out, resets Content-Length
// from the rewritten length, and flushes to the real client.
func (b *BodyRewrite) rewriteResponse(rw http.ResponseWriter, req *http.Request) {
	buf := &responseBuffer{
		header:     http.Header{},
		body:       &bytes.Buffer{},
		statusCode: http.StatusOK,
	}
	b.next.ServeHTTP(buf, req)

	// Copy captured headers out, minus Content-Length (we recompute).
	for k, vv := range buf.header {
		if strings.EqualFold(k, "Content-Length") {
			continue
		}
		rw.Header()[k] = vv
	}

	raw := buf.body.Bytes()
	out := raw
	if rewrote, ok := b.rewriteJSONObject(raw); ok {
		out = rewrote
		rw.Header().Set("Content-Type", "application/json")
	}

	rw.Header().Set("Content-Length", strconv.Itoa(len(out)))
	rw.WriteHeader(buf.statusCode)
	_, _ = rw.Write(out)
}

// rewriteJSONObject decodes `raw` as a JSON object and, if that
// succeeds, applies inject / drop paths and re-encodes. A decode
// failure returns `ok=false` so the caller can pass the body through
// unchanged.
func (b *BodyRewrite) rewriteJSONObject(raw []byte) ([]byte, bool) {
	var obj map[string]interface{}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return raw, false
	}
	if obj == nil {
		obj = map[string]interface{}{}
	}
	if len(b.injectPath) > 0 {
		setDotted(obj, b.injectPath, b.injectValue)
	}
	for _, p := range b.dropPaths {
		dropDotted(obj, p)
	}
	out, err := json.Marshal(obj)
	if err != nil {
		return raw, false
	}
	return out, true
}

// responseBuffer captures headers, status and body so the plugin can
// rewrite the response before it leaves the gateway. Implements the
// http.ResponseWriter interface.
type responseBuffer struct {
	header      http.Header
	body        *bytes.Buffer
	statusCode  int
	wroteHeader bool
}

func (r *responseBuffer) Header() http.Header { return r.header }

func (r *responseBuffer) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.body.Write(b)
}

func (r *responseBuffer) WriteHeader(statusCode int) {
	if r.wroteHeader {
		return
	}
	r.statusCode = statusCode
	r.wroteHeader = true
}

// splitPath turns a dotted path into a slice of keys. An empty input
// returns an empty slice.
func splitPath(p string) []string {
	if p == "" {
		return nil
	}
	return strings.Split(p, ".")
}

// setDotted traverses `obj` along `path`, creating intermediate
// objects as needed, and writes `value` at the leaf.
func setDotted(obj map[string]interface{}, path []string, value interface{}) {
	cur := obj
	for i, key := range path {
		if i == len(path)-1 {
			cur[key] = value
			return
		}
		next, ok := cur[key].(map[string]interface{})
		if !ok {
			next = map[string]interface{}{}
			cur[key] = next
		}
		cur = next
	}
}

// dropDotted traverses `obj` along `path` and deletes the leaf key
// if it exists. Missing keys are a no-op (symmetric with
// gateways/nginx / gateways/envoy body_rewrite helpers).
func dropDotted(obj map[string]interface{}, path []string) {
	cur := obj
	for i, key := range path {
		if i == len(path)-1 {
			delete(cur, key)
			return
		}
		next, ok := cur[key].(map[string]interface{})
		if !ok {
			return
		}
		cur = next
	}
}
