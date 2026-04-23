# gateways/tyk/_policies

Single permissive default policy referenced by every Tyk profile that
ships a JWT-protected API. The policy is intentionally rate-limit-free
/ quota-free / unrestricted so that Tyk's auth pipeline only enforces
the signature check itself; profile-level rate limiting comes from the
API definition's per-endpoint or `global_rate_limit` fields, not from
session policy.

## `policies.json`

Tyk's file-based policy loader (`policies.policy_source: "file"` in
`tyk.standalone.conf`) is **strict JSON** — no comments allowed (it
chokes on stray string keys with `json: cannot unmarshal string into
Go value of type user.Policy`). Documentation lives here instead of
inline.

`bench-default-policy.access_rights` lists every `api_id` that may
attach this policy via its `jwt_default_policies`:

| `api_id`               | Used by                                          |
| ---------------------- | ------------------------------------------------ |
| `bench`                | profiles `p02-jwt`, `p12-full-pipeline`          |
| `p03-jwks-rs256-basic` | profile `p03-jwks-rs256-basic`                   |

Adding more `api_id`s here is harmless because
`partitions.acl = true` means the policy only contributes ACL info —
the rate / quota partitions are not touched.
