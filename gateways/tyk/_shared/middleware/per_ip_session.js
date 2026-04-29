// gateways/tyk/_shared/middleware/per_ip_session.js
//
// JSVM pre-middleware shared by tyk/p06-rl-dynamic-low and
// tyk/p07-rl-dynamic-high. Tyk Classic OSS has no native primitive
// for "rate-limit by request header" — global_rate_limit and
// extended_paths.rate_limit both bucket on the API or path, not on
// arbitrary header values. The documented Tyk pattern for this axis
// is per-key sessions (because session-level rate limits do bucket
// per key) plus a JSVM pre-middleware that:
//
//   1. reads the bench's X-Real-IP header
//   2. derives a deterministic session-key string from it
//   3. on the first sighting of an IP, calls /tyk/keys/<key> via
//      TykMakeHTTPRequest to provision a session whose rate/per
//      matches the canonical bucket
//   4. rewrites the request's Authorization header to that key so
//      Tyk's normal AuthToken middleware (which runs AFTER pre)
//      picks the session up and applies its rate limit
//
// The cache (`seen_ips`) lives at the JSVM module scope: each Tyk
// worker shares one otto VM per middleware file, so the cache
// persists across requests within the gateway process. A stale entry
// after a Tyk restart would re-provision the session via /tyk/keys
// — Tyk's PUT semantics make that idempotent (existing key is
// replaced with the same shape).
//
// The bucket size (`BENCH_RL_RATE`) is read from the API definition's
// `config_data` block so this single file serves both p05 (rate=10)
// and p06 (rate=100). Keeping the rate out of the JS file means the
// matrix-readability invariant holds: every cell-level value lives
// in the cell's own apis/bench.json, not buried in a shared script.

var seen_ips = {};

var per_ip_session = new TykJS.TykMiddleware.NewMiddleware({});

per_ip_session.NewProcessRequest(function (request, session, config) {
    // config.config_data is the API definition's `config_data` field
    // — the only sanctioned channel for per-API JSVM parameters in
    // Tyk Classic. We pass BENCH_RL_RATE / BENCH_RL_PER through
    // there. Default falls back to a safe deny-everything value so a
    // misconfigured API def fails loud rather than silently dropping
    // the rate limit.
    var rate = parseInt(config.config_data.BENCH_RL_RATE, 10);
    var per  = parseInt(config.config_data.BENCH_RL_PER,  10);
    if (isNaN(rate) || isNaN(per) || rate <= 0 || per <= 0) {
        request.ReturnOverrides.ResponseError =
            "per_ip_session: BENCH_RL_RATE / BENCH_RL_PER missing or invalid in config_data";
        request.ReturnOverrides.ResponseCode = 500;
        return per_ip_session.ReturnData(request, session.meta_data);
    }

    // Tyk normalises header keys to canonical-MIME form
    // (X-Real-Ip, not X-Real-IP) before populating request.Headers.
    // We try the canonical first and the all-caps fallback in case a
    // future Tyk version changes the canonicalisation.
    var ip = "";
    if (request.Headers["X-Real-Ip"] && request.Headers["X-Real-Ip"][0]) {
        ip = request.Headers["X-Real-Ip"][0];
    } else if (request.Headers["X-Real-IP"] && request.Headers["X-Real-IP"][0]) {
        ip = request.Headers["X-Real-IP"][0];
    }
    if (!ip) {
        request.ReturnOverrides.ResponseError = "missing X-Real-IP header";
        request.ReturnOverrides.ResponseCode = 400;
        return per_ip_session.ReturnData(request, session.meta_data);
    }

    // Sanitise the IP into something Tyk will accept as a key name —
    // dots and colons are stripped to keep the URL path tidy. The
    // rate bucket is part of the key so p05 and p06 don't collide if
    // both APIs ever boot in the same Tyk node (defensive — we
    // currently boot one profile at a time).
    var key = "bench_ip_r" + rate + "_" + ip.replace(/[^0-9A-Za-z]/g, "_");

    if (!seen_ips[key]) {
        var sess = {
            rate: rate,
            per: per,
            quota_max: -1,
            quota_renews: 0,
            quota_remaining: -1,
            allowance: rate,
            org_id: "gateway-benchmarks",
            is_inactive: false,
            access_rights: {
                "bench": {
                    api_id: "bench",
                    api_name: "bench",
                    versions: ["Default"]
                }
            }
        };

        // Synchronous round-trip to the local Tyk admin API. In this
        // harness the admin API shares the same :9080 listener as the
        // data plane (Classic mode) and is gated by
        // X-Tyk-Authorization.
        // Notes on the request shape:
        //   * the helper is `TykMakeHttpRequest` (lowercase 'ttp')
        //     — the all-caps spelling that the public docs sometimes
        //     show is wrong and yields `ReferenceError: not defined`.
        //   * `Domain` is mandatory: without it Tyk's net/http call
        //     fails with `unsupported protocol scheme ""`. We use
        //     127.0.0.1 because the JSVM runs in-process with the
        //     gateway listener.
        var resp = TykMakeHttpRequest(JSON.stringify({
            Method:   "POST",
            Domain:   "http://127.0.0.1:9080",
            Resource: "/tyk/keys/" + key,
            Body:     JSON.stringify(sess),
            Headers: {
                "X-Tyk-Authorization": "gateway-benchmarks",
                "Content-Type":        "application/json"
            },
            FormData: {}
        }));

        var parsed = {};
        try { parsed = JSON.parse(resp); } catch (e) { parsed = {}; }
        if (parsed.Code === undefined || parsed.Code !== 200) {
            request.ReturnOverrides.ResponseError =
                "per_ip_session: /tyk/keys POST for " + ip + " returned " +
                (parsed.Code || "unknown") + " body=" +
                (parsed.Body || "").substr(0, 200);
            request.ReturnOverrides.ResponseCode = 502;
            return per_ip_session.ReturnData(request, session.meta_data);
        }

        seen_ips[key] = true;
    }

    // Replace whatever the client sent (or didn't send) in
    // Authorization with the synthesised key. Tyk's AuthToken
    // middleware (default for use_keyless=false APIs) will read
    // exactly this header value, hash it, and look up the session we
    // just provisioned.
    request.SetHeaders["Authorization"] = key;

    return per_ip_session.ReturnData(request, session.meta_data);
});
