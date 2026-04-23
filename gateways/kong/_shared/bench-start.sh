#!/usr/bin/env bash
# gateways/kong/_shared/bench-start.sh
#
# Custom entrypoint shim for the kong cell.
#
# WHY THIS EXISTS
# ===============
# Kong's nginx template hard-codes the X-Forwarded-For header to be
# stamped from `$upstream_x_forwarded_for`, set by Kong's runloop in
# `runloop.access.after`:
#
#     proxy_set_header X-Forwarded-For $upstream_x_forwarded_for;
#
# Kong's plugin lifecycle is:
#
#     runloop.access.before  →  plugins[access]  →  runloop.access.after
#
# which means a plugin (request-transformer, pre-function, …) trying
# to drop X-Forwarded-For via `kong.service.request.clear_header()`
# or `ngx.req.clear_header()` ALWAYS loses to the runloop's later
# write of `$upstream_x_forwarded_for`. p08-req-headers and the
# composed p12-full-pipeline both need the header gone.
#
# WHAT THIS DOES
# ==============
# Pre-patches Kong's nginx template with three minimal edits before
# delegating to the stock /entrypoint.sh:
#
#   1. Adds `set $bench_xff ''` next to the existing
#      `set $upstream_x_forwarded_for ''` initializer block, in BOTH
#      proxy locations (`location /` for buffered, `@unbuffered` for
#      unbuffered) and `@grpc` for symmetry.
#
#   2. Re-routes `proxy_set_header X-Forwarded-For` (and the
#      `grpc_set_header` twin) from `$upstream_x_forwarded_for` to
#      our writable `$bench_xff` in those same three locations.
#
#   3. Initializes `$bench_xff` to the sentinel `__BENCH_XFF_DEFAULT__`
#      and adds a shim inside the `access_by_lua_block`:
#
#          if ngx.var.bench_xff == "__BENCH_XFF_DEFAULT__" then
#            ngx.var.bench_xff = ngx.var.upstream_x_forwarded_for or ""
#          end
#
#      AFTER `Kong.access()` returns. The sentinel lets us tell apart
#      "profile didn't touch the variable" (=> mirror Kong's default
#      XFF; same observable behaviour as vanilla Kong) from "profile
#      explicitly set it to empty string" (=> drop the header).
#
# A profile that wants the header gone (p07, p11) just sets
# `ngx.var.bench_xff = ""` from a `pre-function`/`post-function`
# plugin in the access phase; an empty `proxy_set_header` value
# tells nginx not to send the header at all.
#
# IDEMPOTENCE
# ===========
# All three sed steps are guarded by a needle-presence check; the
# script is safe to re-run on the same image (the second invocation
# is a no-op). It does NOT rebuild Kong, only edits the template
# files in-place — patches survive only the container lifetime.
#
# This mirrors the pattern used by `gateways/apisix/_shared/bench-start.sh`
# which patches APISIX's generated nginx.conf for the same reason.

set -Eeuo pipefail

TEMPLATE=/usr/local/share/lua/5.1/kong/templates/nginx_kong.lua

if [[ -f "${TEMPLATE}" ]]; then
    if grep -qF "set \$upstream_x_forwarded_for    ''" "${TEMPLATE}" \
        && ! grep -qF "set \$bench_xff" "${TEMPLATE}"; then

        echo "[bench-start] patching ${TEMPLATE} for X-Forwarded-For overridability" >&2

        # 1. Add `set $bench_xff '__BENCH_XFF_DEFAULT__';` after every
        #    `set $upstream_x_forwarded_for '';` line. The sentinel
        #    is the "profile hasn't touched it" marker the access
        #    shim below checks for.
        sed -i "/set \$upstream_x_forwarded_for    '';/a\\
        set \$bench_xff                  '__BENCH_XFF_DEFAULT__';" "${TEMPLATE}"

        # 2. Re-route X-Forwarded-For to $bench_xff
        #    (proxy_set_header in both locations + grpc_set_header).
        sed -i \
            -e 's|proxy_set_header      X-Forwarded-For    $upstream_x_forwarded_for;|proxy_set_header      X-Forwarded-For    $bench_xff;|g' \
            -e 's|grpc_set_header      X-Forwarded-For    $upstream_x_forwarded_for;|grpc_set_header      X-Forwarded-For    $bench_xff;|g' \
            "${TEMPLATE}"

        # 3. Conditional mirror after Kong.access() — only fills
        #    $bench_xff with kong's computed XFF if the sentinel is
        #    still in place. A plugin that sets bench_xff to "" gets
        #    its empty string preserved (header dropped).
        sed -i \
            's|^        Kong.access()$|        Kong.access()\n        if ngx.var.bench_xff == "__BENCH_XFF_DEFAULT__" then ngx.var.bench_xff = ngx.var.upstream_x_forwarded_for or "" end|' \
            "${TEMPLATE}"
    fi
fi

exec /entrypoint.sh "$@"
