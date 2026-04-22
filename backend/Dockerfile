# syntax=docker/dockerfile:1.7
#
# Benchmark backend = vendored mccutchen/go-httpbin v2.22.1 (MIT).
# Upstream sources live in ./upstream/ unchanged; see ./NOTICE.
#
# The final image is FROM scratch: statically linked binary, no shell,
# no package manager, no libc. See ../docs/REPRODUCIBILITY.md.

ARG GO_VERSION=1.25
ARG GO_HTTPBIN_VERSION=v2.22.1
ARG GO_HTTPBIN_COMMIT=f26ca5854f665e80255940d5aab7f119904c3875

# ---------------------------------------------------------------------------
# Stage 1 — static build
# ---------------------------------------------------------------------------
FROM golang:${GO_VERSION}-alpine AS builder

ARG GO_HTTPBIN_VERSION
ARG GO_HTTPBIN_COMMIT
ARG BUILD_DATE=unknown

WORKDIR /src
COPY upstream/ ./

# CGO_ENABLED=0   -> statically linked, works in FROM scratch.
# -trimpath       -> strips absolute paths from the binary, reproducible.
# -ldflags "-s -w" -> drop DWARF + symbol tables, smaller binary.
# -ldflags -X     -> embed version metadata expected by cmd/go-httpbin/main.go.
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux \
    go build \
        -trimpath \
        -ldflags="-s -w \
            -X main.version=${GO_HTTPBIN_VERSION} \
            -X main.commit=${GO_HTTPBIN_COMMIT} \
            -X main.buildDate=${BUILD_DATE}" \
        -o /out/go-httpbin \
        ./cmd/go-httpbin

# ---------------------------------------------------------------------------
# Stage 2 — minimal runtime
# ---------------------------------------------------------------------------
FROM scratch

ARG GO_HTTPBIN_VERSION
ARG GO_HTTPBIN_COMMIT

LABEL org.opencontainers.image.title="gateway-benchmarks-backend" \
      org.opencontainers.image.description="Vendored mccutchen/go-httpbin used as the synthetic benchmark backend." \
      org.opencontainers.image.source="https://github.com/wallarm/gateway-benchmarks" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Wallarm" \
      io.wallarm.benchmarks.upstream="github.com/mccutchen/go-httpbin" \
      io.wallarm.benchmarks.upstream.version="${GO_HTTPBIN_VERSION}" \
      io.wallarm.benchmarks.upstream.commit="${GO_HTTPBIN_COMMIT}"

COPY --from=builder /out/go-httpbin /go-httpbin
COPY --from=builder /src/LICENSE    /LICENSE.go-httpbin

# Run as non-root (numeric UID because scratch has no /etc/passwd).
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/go-httpbin"]
CMD ["-host", "0.0.0.0", "-port", "8080", "-max-body-size", "10485760", "-max-duration", "30s"]
