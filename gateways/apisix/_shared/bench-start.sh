#!/usr/bin/env bash
#
# gateways/apisix/_shared/bench-start.sh
#
# Thin wrapper around APISIX's upstream standalone bootstrap. Everything
# is identical to the stock apache/apisix:3.15.0-debian entrypoint
# (PREFIX, `apisix init`, `openresty -g daemon off`) except for a single
# post-init surgery on the generated nginx.conf:
#
#   proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
#
# becomes
#
#   set                $bench_xff        $proxy_add_x_forwarded_for;
#   proxy_set_header   X-Forwarded-For   $bench_xff;
#
# This is the minimum viable escape hatch that lets `p08-req-headers` and
# `p12-full-pipeline` satisfy the canonical fixture's
# `backend_missed_header: ["X-Forwarded-For"]` assertion without
# forking APISIX.
#
# Why this is needed:
#   * APISIX's nginx template (apisix/cli/ngx_tpl.lua) hardcodes
#     `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for` at
#     the upstream-proxy step, AFTER every plugin hook has run. The
#     nginx semantics of `$proxy_add_x_forwarded_for` guarantee a
#     non-empty upstream header (client XFF + `$remote_addr`, or
#     `$remote_addr` alone), so the `proxy-rewrite.headers.remove` /
#     `ngx.req.set_header(..., nil)` idioms cannot drop the header from
#     the upstream request. This is a known limitation — see the
#     comment right next to line 848 in APISIX's upstream ngx_tpl.lua
#     ("the `X-Forwarded-For` header is not updated through these
#     variables. because it is set by the `proxy_add_x_forwarded_for`
#     directive"). Routing the value through a writable `set`
#     variable gives us a per-route override surface via
#     `ngx.var.bench_xff = ""` in a `serverless-pre-function` at the
#     `access` phase — nginx treats the empty-string value of a
#     proxy_set_header as "do not forward this header", which is
#     exactly what p07 asserts.
#   * The patch is idempotent (safe to re-run across container
#     restarts) and applies to EVERY profile, but only profiles that
#     explicitly write `ngx.var.bench_xff = ""` see any behaviour
#     change. Defaults (`$proxy_add_x_forwarded_for`) match APISIX's
#     out-of-the-box semantics byte-for-byte.
#   * We deliberately avoid forking `apisix/cli/ngx_tpl.lua` itself:
#     that file is huge, version-drifts rapidly between APISIX
#     releases, and mounting it over the image would give us a stale
#     copy on the next `docker pull`. A post-init sed targets one
#     directive in the *generated* nginx.conf and degrades safely if
#     the directive text ever changes (we fall through without
#     patching; p07/p11 would then surface as FEATURE-MISSING, which
#     is the honest outcome).
#
# This script is the container entrypoint (see docker-compose.yaml
# `entrypoint:`). It consumes the same `docker-start` argv as the
# upstream image and is otherwise a byte-for-byte clone of
# apache/apisix-docker's docker-entrypoint.sh for the standalone
# branch.

set -eo pipefail

PREFIX=${APISIX_PREFIX:=/usr/local/apisix}

if [[ "${1:-}" == "docker-start" ]]; then
    if [ "${APISIX_STAND_ALONE:-false}" = "true" ]; then
        # config.yaml is mounted by docker-compose — just let the
        # upstream's standalone sanity-check run.
        if [ ! -f "${PREFIX}/conf/config.yaml" ]; then
            cat > "${PREFIX}/conf/config.yaml" << _EOC_
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
_EOC_
        else
            source /check_standalone_config.sh
        fi

        # apisix.yaml is mounted by docker-compose too — same defensive
        # defaulting as upstream in case a profile dir is empty.
        if [ ! -f "${PREFIX}/conf/apisix.yaml" ]; then
            cat > "${PREFIX}/conf/apisix.yaml" << _EOC_
routes:
  -
#END
_EOC_
        fi

        /usr/bin/apisix init
    else
        /usr/bin/apisix init
        /usr/bin/apisix init_etcd
    fi

    # Post-init surgery: make X-Forwarded-For overridable per route.
    # Idempotent — re-running against an already-patched nginx.conf is
    # a no-op because the `set $bench_xff ...;` line is already there.
    if grep -q 'proxy_set_header   X-Forwarded-For      \$proxy_add_x_forwarded_for;' \
        "${PREFIX}/conf/nginx.conf"; then
        sed -i \
            -e '/proxy_set_header   X-Forwarded-For      \$proxy_add_x_forwarded_for;/i\            set                $bench_xff             $proxy_add_x_forwarded_for;' \
            -e 's|proxy_set_header   X-Forwarded-For      $proxy_add_x_forwarded_for;|proxy_set_header   X-Forwarded-For      $bench_xff;|g' \
            "${PREFIX}/conf/nginx.conf"
    fi

    # Stale-socket cleanup from the upstream entrypoint.
    if [ -e "${PREFIX}/conf/config_listen.sock" ]; then
        rm -f "${PREFIX}/conf/config_listen.sock"
    fi
    if [ -e "${PREFIX}/logs/worker_events.sock" ]; then
        rm -f "${PREFIX}/logs/worker_events.sock"
    fi

    exec /usr/local/openresty/bin/openresty -p "${PREFIX}" -g 'daemon off;'
fi

exec "$@"
