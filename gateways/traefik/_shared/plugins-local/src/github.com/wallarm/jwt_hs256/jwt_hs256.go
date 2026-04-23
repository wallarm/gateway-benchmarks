// Package jwt_hs256 implements a minimal Traefik middleware plugin
// that validates an HS256 JWT carried in `Authorization: Bearer <jwt>`
// (or any header / scheme the operator picks) against a shared secret.
// It is loaded by Traefik's Yaegi-based plugin interpreter; every
// stdlib import below is on the Yaegi-supported list (crypto/hmac,
// crypto/sha256, encoding/base64, encoding/json, time, net/http,
// strings, context).
//
// Design scope (deliberately narrow so the plugin is auditable and
// 1:1 with docs/POLICIES.md § p02 — JWT validation, HS256 only):
//
//   * One signing secret (string), shared with every other gateway
//     via gateways/_reference/jwt/secret.txt. The plugin does NOT
//     accept a list of secrets, a JWKS URL, or any other key-source
//     surface — those axes belong to the p03
//     `p03-jwks-rs256-basic` scenario, not to canonical p02.
//
//   * One algorithm: HS256 (HMAC-SHA-256). Tokens whose `alg` header
//     is anything else (RS256, ES256, none, ...) are rejected. We
//     refuse to silently transit "alg=none" tokens which the JWT spec
//     would otherwise allow and which has been the root of every
//     well-known JWT bypass CVE.
//
//   * One token shape: three base64url segments separated by `.`
//     (RFC 7515 § 3 Compact Serialization). Padding is not allowed
//     (RawURLEncoding). Any other shape -> reject.
//
//   * Two claims are validated when present:
//       - `exp`  must be > now  (with optional `leewaySeconds`)
//       - `nbf`  must be <= now (with optional `leewaySeconds`)
//     `iss` / `aud` / `sub` are NOT validated — the canonical p02
//     fixture exercises only signature + expiry, and adding extra
//     claim filters here would diverge from the cross-gateway
//     contract.
//
//   * Single rejection status code (default 401 with empty body and
//     `WWW-Authenticate: <scheme>` per RFC 6750 § 3). The fixture
//     asserts on status code only, so we deliberately ship no error
//     body — every other gateway in the matrix matches this shape.
//
// The plugin is intentionally API-symmetric with the
// `gateways/nginx/_shared/lualib/jwt_hs256.lua` and
// `gateways/envoy/_shared/lualib/jwt_hs256.lua` helpers (same secret
// path, same alg gate, same exp/nbf semantics). A reviewer can read
// any one column's implementation and trust the fixture semantics
// across the whole matrix.
//
// Why not pull a community plugin?
// --------------------------------
// Every public Traefik JWT plugin we vetted (see
// gateways/traefik/p02-jwt/NOTES.md before this file landed) either
// (a) bundled extra knobs the canonical fixture does not exercise
// (audience, issuer, RS256 fallbacks), (b) had no recent commits, or
// (c) pulled in cryptographic helpers that Yaegi's restricted stdlib
// does not expose (golang.org/x/crypto/...). Shipping ~100 lines of
// stdlib-only Go inside the repo is cheaper to audit than vendoring
// any of those dependencies.
package jwt_hs256

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

// Config is the plugin configuration shape exposed to dynamic.yaml.
// Only the fields below are honoured; anything else in the plugin
// stanza is ignored silently by Yaegi's JSON decoder.
type Config struct {
	// Secret is the HS256 signing secret. Required — an empty secret
	// causes every token to be rejected (we refuse to accept the
	// "empty secret" footgun where any HMAC over the empty key would
	// pass).
	Secret string `json:"secret,omitempty"`

	// HeaderName is the request header carrying the token. Default
	// "Authorization".
	HeaderName string `json:"headerName,omitempty"`

	// Scheme is the prefix expected before the token, e.g. "Bearer".
	// Default "Bearer". Comparison is case-insensitive (RFC 6750 § 2.1
	// allows "bearer" and "BEARER" as well).
	Scheme string `json:"scheme,omitempty"`

	// LeewaySeconds is the slop window applied to exp/nbf checks to
	// tolerate small clock skews. Default 0 (strict).
	LeewaySeconds int `json:"leewaySeconds,omitempty"`

	// RejectStatusCode is the status used when validation fails.
	// Default 401. Set to 403 if you want to follow APISIX-style
	// rejection codes (the fixture asserts 401 — leave the default
	// in place for canonical p02).
	RejectStatusCode int `json:"rejectStatusCode,omitempty"`
}

// CreateConfig returns the default plugin config (required by
// Traefik's plugin contract).
func CreateConfig() *Config {
	return &Config{
		HeaderName:       "Authorization",
		Scheme:           "Bearer",
		LeewaySeconds:    0,
		RejectStatusCode: http.StatusUnauthorized,
	}
}

// JWTHS256 is the instantiated middleware.
type JWTHS256 struct {
	next             http.Handler
	name             string
	secret           []byte
	headerName       string
	scheme           string
	leewaySeconds    int64
	rejectStatusCode int
}

// New is the Traefik plugin constructor.
func New(_ context.Context, next http.Handler, cfg *Config, name string) (http.Handler, error) {
	headerName := cfg.HeaderName
	if headerName == "" {
		headerName = "Authorization"
	}
	scheme := cfg.Scheme
	if scheme == "" {
		scheme = "Bearer"
	}
	rejectStatusCode := cfg.RejectStatusCode
	if rejectStatusCode == 0 {
		rejectStatusCode = http.StatusUnauthorized
	}
	leewaySeconds := cfg.LeewaySeconds
	if leewaySeconds < 0 {
		leewaySeconds = 0
	}
	return &JWTHS256{
		next:             next,
		name:             name,
		secret:           []byte(cfg.Secret),
		headerName:       headerName,
		scheme:           scheme,
		leewaySeconds:    int64(leewaySeconds),
		rejectStatusCode: rejectStatusCode,
	}, nil
}

// ServeHTTP runs the validation pipeline and either calls next or
// rejects with the configured status code. Empty body, no error
// payload — every other gateway in the matrix follows the same
// contract.
func (j *JWTHS256) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	if len(j.secret) == 0 {
		j.reject(rw)
		return
	}
	raw := req.Header.Get(j.headerName)
	if raw == "" {
		j.reject(rw)
		return
	}
	// RFC 6750 § 2.1: `Authorization: Bearer <token>`. We only honour
	// the configured scheme (default "Bearer"); "Basic", "Digest" and
	// any non-token-shape header value land in reject.
	parts := strings.SplitN(raw, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], j.scheme) {
		j.reject(rw)
		return
	}
	token := strings.TrimSpace(parts[1])
	if token == "" {
		j.reject(rw)
		return
	}
	if !j.verify(token) {
		j.reject(rw)
		return
	}
	j.next.ServeHTTP(rw, req)
}

// reject writes the canonical 401 with WWW-Authenticate per
// RFC 6750 § 3. No error body — fixtures assert on status only.
func (j *JWTHS256) reject(rw http.ResponseWriter) {
	rw.Header().Set("WWW-Authenticate", j.scheme)
	rw.WriteHeader(j.rejectStatusCode)
}

// verify implements the three-segment HS256 check:
//
//  1. Split on `.` -> exactly three parts.
//  2. Decode header (base64url, no padding); JSON-parse; require
//     `alg=HS256`. Refuse `alg=none`, RS256, ES256, etc.
//  3. Recompute HMAC-SHA-256 over `<headerSeg>.<payloadSeg>` with
//     the configured secret; compare in constant time against the
//     base64url-decoded signature segment.
//  4. Decode payload (base64url, no padding); JSON-parse; check
//     `exp` and `nbf` against `time.Now()` with optional leeway.
//
// Returns true only when every step passes.
func (j *JWTHS256) verify(token string) bool {
	segments := strings.Split(token, ".")
	if len(segments) != 3 {
		return false
	}
	headerSeg, payloadSeg, sigSeg := segments[0], segments[1], segments[2]
	if headerSeg == "" || payloadSeg == "" || sigSeg == "" {
		return false
	}

	headerBytes, err := base64.RawURLEncoding.DecodeString(headerSeg)
	if err != nil {
		return false
	}
	var header struct {
		Alg string `json:"alg"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return false
	}
	if header.Alg != "HS256" {
		return false
	}

	expectedSig, err := base64.RawURLEncoding.DecodeString(sigSeg)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, j.secret)
	mac.Write([]byte(headerSeg))
	mac.Write([]byte("."))
	mac.Write([]byte(payloadSeg))
	if !hmac.Equal(expectedSig, mac.Sum(nil)) {
		return false
	}

	payloadBytes, err := base64.RawURLEncoding.DecodeString(payloadSeg)
	if err != nil {
		return false
	}
	// We deliberately decode into map[string]json.RawMessage and then
	// re-decode each claim individually as int64. The textbook approach
	// (a struct with a custom UnmarshalJSON-bearing field) does NOT
	// work under Yaegi: the interpreter's reflect-driven JSON decoder
	// silently skips method dispatch on user-declared types, so the
	// custom UnmarshalJSON never fires and the decode bombs with
	// "cannot unmarshal number into Go struct". Per-key RawMessage
	// decode sticks to plain stdlib types Yaegi hands us byte-for-byte.
	var claims map[string]json.RawMessage
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return false
	}
	now := time.Now().Unix()
	if expRaw, ok := claims["exp"]; ok {
		var exp int64
		if err := json.Unmarshal(expRaw, &exp); err != nil {
			return false
		}
		if now-j.leewaySeconds > exp {
			return false
		}
	}
	if nbfRaw, ok := claims["nbf"]; ok {
		var nbf int64
		if err := json.Unmarshal(nbfRaw, &nbf); err != nil {
			return false
		}
		if now+j.leewaySeconds < nbf {
			return false
		}
	}
	return true
}

