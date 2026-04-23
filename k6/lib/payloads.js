// k6/lib/payloads.js
//
// Canonical request payloads referenced by every scenario that POSTs
// a body. Values mirror docs/POLICIES.md byte-for-byte so the load
// phase exercises the same JSON shape the parity attestation does
// (otherwise a body-rewrite scenario could pass parity but exercise
// an unrelated payload at load time).
//
// Per TASK §12 ("payload padding must use a seeded RNG"), any future
// payload that needs randomness must derive from `lib/seed.js` (not
// added yet; first added in the iteration that lands the heavy-
// payload scenarios). Static payloads stay here.

// Body shape for p10-req-body. The gateway must add `bench.injected =
// true` and remove `secret`, then the backend echoes it. Matches
// fixtures/p10-req-body.jsonl line 1.
export const p09RequestBody = Object.freeze({
    msg: 'hello',
    secret: 'please-drop-me',
    bench: { from_client: true },
});

// Body shape for p12-full-pipeline. Same as p09 plus the JWT path is
// exercised via the Authorization header (set by the scenario, not
// here).
export const p11RequestBody = p09RequestBody;
