# tyk · p05-rl-endpoint

## Verdict

**PASS 4/4** on tyk 5.11.1 OSS.

| # | Probe                                                  | Expected     | Observed              | Verdict |
| - | ------------------------------------------------------ | ------------ | --------------------- | ------- |
| 1 | single GET on free endpoint                            | `200`        | `200`                 | **PASS** |
| 2 | single GET on limited endpoint below 100 rps           | `200`        | `200`                 | **PASS** |
| 3 | 1200 req burst on `/anything/limited`                  | ≥150×429 ±50 | 1102×429 / 98×2xx     | **PASS** |
| 4 | 1200 req burst on `/anything/free` (must NOT 429)      | ≥1100×2xx, 0×429 | 1200×2xx / 0×429  | **PASS** |

## Native primitive

`extended_paths.rate_limit` on the API definition's version block —
each entry binds one rate bucket to a `(path, method)` pair. Paths
that do not match any rate_limit entry pass through unrestricted,
which is exactly what the canonical scoping invariant demands.

```jsonc
{
  "version_data": {
    "versions": {
      "Default": {
        "use_extended_paths": true,
        "extended_paths": {
          "rate_limit": [{
            "path":   "/anything/limited",
            "method": "GET",
            "rate":   100,
            "per":    1
          }]
        }
      }
    }
  }
}
```

`use_extended_paths: true` is mandatory — Tyk's APISpec loader skips
the entire `extended_paths` block if it is left at the default
`false`, which would silently leave the API unrestricted.

We deliberately do **not** set `global_rate_limit` here so the burst
on `/anything/free` is not throttled by an API-wide bucket.

The 1102 × 429 count on `/anything/limited` is well above the
canonical floor of 150: the 100-rps bucket is exhausted in the first
~100 ms of the burst and the remaining ~900 ms see no replenishment
during the parity sweep, so almost every request after the warm-up
slice gets `429`'d. The matrix only requires us to land above the
floor.

## Files in this profile

| Path                         | Role                                                 |
| ---------------------------- | ---------------------------------------------------- |
| `apis/bench.json`            | Tyk Classic API def with `extended_paths.rate_limit` on `/anything/limited` |
| `setup.sh`                   | Readiness + API-loaded check + dual smoke probe      |
| `NOTES.md`                   | This document                                        |
