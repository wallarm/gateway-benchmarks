# Gateway Benchmarks — Product Requirements

Reference report layout: described in [docs/REPORT.md](./docs/REPORT.md); a concrete reference artefact will be produced in Phase 7.

## 1. Purpose

Create a reproducible, public-grade benchmark that compares the Wallarm API Gateway to six peers using a single matrix of policy configurations and traffic profiles.
The framework is expected to serve both as material for external comparisons and publications and as an internal tool for tracking performance regressions.

## 2. Scope

In scope:

- Proxying throughput and latency under various policy configurations and traffic shapes.
- Comparative memory consumption and network bandwidth.
- HTTP/1.1 plaintext and HTTP/1.1 over TLS.
- Reproducible runs on a developer's local machine and on AWS.

Out of scope:

- HTTP/2, HTTP/3, gRPC.
- Gateway clustering, distributed rate limiting, or HA failover.
- OS/TCP stack tuning comparisons.
- WAF / AppSec correctness or performance.
- Functional correctness testing beyond parity attestation.

## 3. Products Under Test

The framework must exercise the following gateways:

- nginx
- apisix
- Wallarm API Gateway
- kong
- envoy
- traefik
- tyk

A synthetic backend service is included as a **direct-connect baseline** (no gateway) so every data cell can report an "overhead vs. baseline" figure.

## 4. Policy Profiles

Ten policy profiles must be tested. Each is a specific configuration of the gateway under test.

- **Vanilla** — no policies applied; pure proxy.
- **JWT verification** — tokens validated against a shared secret (or a shared static JWKS if the gateway does not support a static secret).
- **Static rate limit** — service-wide rate limit.
- **Dynamic rate limit, low cardinality** — per-key limit based on a dynamic request attribute (IP, header, or query parameter); the key pool has ~100 unique values.
- **Dynamic rate limit, high cardinality** — same mechanism, but with tens of thousands of unique keys.
- **Request headers rewrite** — add one header, remove one header.
- **Response headers rewrite** — add one header, remove one header.
- **Request body rewrite** — JSON: add one field, remove one.
- **Response body rewrite** — JSON: add one field, remove one.
- **Full pipeline** — client → JWT check → static rate limit → request header rewrite → request body rewrite → upstream → response header rewrite → response body rewrite → client.

### Parity requirement

Within any policy profile, every gateway must be configured so that **externally observable behaviour is equivalent**: same rate-limit threshold, same validation semantics, same header/field names, same payload transforms. The concrete values (limit size, header names, JSON field names, JWT algorithm, and so on) are chosen by the framework author but must be strictly identical across all gateways.

Each gateway configuration must pass **parity attestation** before its metrics are included in the report. Attestation confirms the policy behaves as specified (e.g. JWT rejects invalid tokens; the rate limiter kicks in at the specified threshold; body/header edits produce the expected diff).

Cells for which a gateway fails parity are explicitly excluded from the report with the reason shown.
If a gateway cannot implement a policy natively (without third-party plugins), the cell is marked as `feature-missing` — a distinct status from parity failure — and visually highlighted in the report.

## 5. Load Profiles

Four load profiles (traffic shapes) must be tested:

- **Sustained** — constant request rate held long enough to collect steady-state metrics.
- **Spike** — repeating cycles of fast ramp-up, hold, and sharp drop.
- **High concurrency** — fixed number of concurrent connections at several predefined levels, to stress connection handling.
- **Heavy payloads** — varying request body sizes, from small to large.

Exact durations, target RPS, concurrency levels, and payload sizes are chosen by the framework author and must be identical for every gateway.
As a reference, buffering settings, HTTP version, worker/thread concurrency, and other cross-cutting settings should match those found in analogous public benchmark repositories (e.g. the Kong and Tyk benchmarks). Where no optimum exists, use the gateway's defaults and document the deviation.

## 6. Protocols

All runs use HTTP/1.1 exclusively. HTTP/2 and HTTP/3 must be forcibly disabled on every gateway, both on the client (downstream) and upstream sides. The flag or setting used to enforce this must be documented.

Two protocol modes are tested:

- **Plaintext HTTP/1.1** — applied to every policy profile.
- **HTTP/1.1 over TLS** — applied only to the Vanilla and Full pipeline profiles. This isolates the clean cost of TLS termination and the "TLS + full pipeline" cost without doubling the overall matrix.

## 7. Test Matrix

Cells per gateway: (10 policy profiles × 4 load profiles) + (2 HTTPS profiles × 4 load profiles) = **48 cells per gateway**.
Cells per cycle: 48 × 7 gateways = **336 cells**.
Plus: one direct-connect backend baseline per (load profile × protocol) combination to power the "overhead" column in every detail table.
Each cell is executed several times per cycle. The report shows the median across repetitions; variance is shown in the detail table. Any cell whose variance exceeds the framework author's threshold is flagged as unstable.

## 8. Metrics

Captured per cell:

- **Throughput** — requests per second (RPS).
- **Latency** — p50, p95, max, avg (per cell).
- **Memory footprint** — peak and steady-state resident memory of the gateway process.
- **Bandwidth** — network bytes per second on the gateway host.
- **Error rate** — reported in four separate columns, not combined into a single percentage:
  - **5XX** — gateway or backend errors.
  - **4XX-expected** — expected 4XX caused by rate limiting in the relevant cells (highlighted red when they appear in non-rate-limit cells).
  - **Client-side** — client-side errors (timeouts, connection resets, read errors from the load generator's point of view).
  - **Excluded** — marker for cells that failed parity or that lack the required feature.

Important: in rate-limit cells the limiter's effectiveness is what is measured, not throughput.
In `static-rl` and low-cardinality `dynamic-rl` cells the generated load deliberately exceeds the limit, so a high 4XX-expected value is expected by design. The interest in those scenarios is the latency distribution for successful traffic and the overhead of maintaining the limiter. High-cardinality `dynamic-rl` cells invert the logic: any single key rarely hits its limit, so the scenario tests the scalability of the counter storage.

## 9. Topology

Every cycle uses the same topology: **three isolated hosts** — load generator, gateway under test, backend. They must be sized so that none becomes a bottleneck at the RPS levels under test.
On AWS these three hosts must be placed in the same **cluster placement group** (or an equivalent) to guarantee sub-millisecond intra-rack latency. The local mode mirrors this topology with three isolated execution units (containers or VMs) whose CPU and memory resources are pinned to match the AWS hosts. This keeps the local and AWS results comparable in ranking (absolute values will differ between hardware classes).
Instance type, container runtime, and provisioning tooling are at the implementer's discretion. To keep continuity with the reference report, the same instance class is preferred.

## 10. Uniform Gateway Settings

Beyond the policy profile, certain gateway settings must be strictly identical across all gateways to avoid giving any product an accidental advantage:

- Request and response buffering must be disabled where possible; otherwise, set to the smallest feasible window and document the deviation.
- Worker/thread concurrency is configured using a single principle for all gateways (for example, one worker per CPU core).
- Access logs are disabled in the hot path (log writing would distort latency measurements).
- HTTP keep-alive is enabled for both downstream and upstream connections.
- Upstream connection pool size is the same everywhere.
- HTTP version is pinned to 1.1 on both sides (per §6).
- Any setting that cannot be fully aligned must be documented as a deviation.

## 11. Report

The output of a cycle is a **single self-contained HTML file** whose layout follows the reference report. Sections in order:

- **Hero** — title, generation timestamp, environment description (cloud provider, instance type, placement, load generator, HTTP version).
- **Executive summary** — ranking table: rank · gateway (coloured badge) · stack (language · version) · average RPS across all cells · max error % · pass ratio (e.g. 46/48) · steady-state memory.
- **Memory footprint grid** — one chart/chip per gateway.
- **Overall profile radar** — relative RPS as a percentage of the best gateway in each scenario.
- **Scenario tabs** — one tab per (policy profile × protocol) combination — 12 tabs in total (10 HTTP + 2 HTTPS).

### Per-tab content

Each tab must start with a detailed scenario description (mandatory):

- **What is tested** — plain-text description of the policy configuration (which policies are enabled, which fields are touched, which values are used).
- **Traffic profile** — description of each load profile applied in this tab.
- **Expected signal** — a one-sentence hypothesis of what the numbers should show.

Below the description: an RPS bar chart, a latency bar chart (p50 and p95), then a detail table with one row per (gateway × load profile) combination, plus a baseline row per load profile. The detail table must include columns for each of the four error categories (see §8) and an overhead-vs-baseline column.

### Machine-readable companion

Alongside the HTML report, a cycle must also produce:

- A wide machine-readable table (CSV/JSON) with per-cell, per-metric data (for later analysis and cycle-to-cycle diffs).
- A **run manifest** capturing every input: gateway image versions/digests, load generator version, provisioning state identifier, orchestrator git SHA, every RNG seed, and timestamps for the whole cycle and every cell.

## 12. Reproducibility

- Gateway images must be pinned by digest, not by tag.
- The load generator must be pinned to a concrete version — **k6 v1.7.1**.
- Every source of pseudo-randomness (JWT pools, dynamic rate-limit key pools, payload padding) must use a seed recorded in the run manifest.
- The run manifest must contain enough inputs for any user to reproduce the cycle bit-for-bit.
- Two consecutive cycles on the same git SHA must produce numerically stable results within the author-defined tolerance for each cell.

## 13. Execution Modes

- **Local** — runs on a single developer machine, fully self-contained (no cloud credentials needed). Intended for framework development, smoke testing, and reduced-matrix validation.
- **AWS** — full matrix runs on provisioned cloud infrastructure. Intended for public reports.

Both modes must produce reports that rank the gateways identically (in the executive summary). Absolute numbers may differ between hardware classes.

## 14. Repository Placement

Public repository at https://github.com/wallarm/gateway-benchmarks to convey neutrality to external reviewers and to make forks trivial.

## 15. Success Criteria

- A full cycle completes end-to-end via a single command in both execution modes without manual intervention.
- Every cell shown on a report was obtained from a configuration that passed parity attestation; excluded cells are visually highlighted and explained.
- Two consecutive cycles on the same git SHA yield stable numbers (within the defined tolerance).
- Local and AWS runs on the same git SHA produce the same gateway ranking in the executive summary.
- An external user can clone the repo, run the smoke matrix locally, and obtain a valid report in a short wall-clock time.

## 16. Documented Deviations

The framework author must explicitly document in the report or in a companion notes file:

- HTTP/1.1 enforcement — the specific flag or configuration used for each gateway, plus a note on any gateway that could not cleanly disable HTTP/2 on any listener.
- JWT fallback — gateways that had to use JWKS instead of a shared secret; the source from which JWKS is served.
- Body / header rewrite support — gateways that cannot rewrite natively (marked as `feature-missing`).
- Buffering — gateways that cannot fully disable buffering; the minimum settings used instead.
- Connection pool size and worker count — any deviation from the uniform settings.
- Any other concessions made to align a gateway's configuration with the parity requirements.

## 17. Synthetic Backend Service

The backend service is the [mccutchen/go-httpbin](https://github.com/mccutchen/go-httpbin) code vendored into `backend/`, with extra endpoints added there if needed.
