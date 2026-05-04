.DEFAULT_GOAL := help
.PHONY: help prereqs-check lint \
	backend-build backend-build-amd64 backend-run backend-smoke \
	orchestrator-build orchestrator-test orchestrator-vet \
	bench-run bench-validate bench-aggregate bench-manifest bench-version bench-report bench-compare-runs \
	perf-local-up perf-local-parity perf-local-cycle-smoke \
	perf-local-run perf-local-report perf-local-down perf-local-clean \
	perf-aws-init perf-aws-deploy perf-aws-run perf-aws-report perf-aws-full-report \
	perf-aws-up perf-aws-destroy perf-aws-ssh-loadgen perf-aws-ssh-gateway perf-aws-ssh-backend \
	perf-aws-down \
	parity-check parity-check-all parity-gateway parity-gateway-all \
	load-gateway load-gateway-load-sweep load-sweep \
	.bench-ports-free

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED     = \033[0;31m
GREEN   = \033[0;32m
YELLOW  = \033[1;33m
CYAN    = \033[0;36m
NC      = \033[0m

# ---------------------------------------------------------------------------
# Variables (override on CLI: `make perf-local-run RUN_ID=demo`)
# ---------------------------------------------------------------------------
RUN_ID           ?= $(shell date -u +%Y%m%dT%H%M%SZ)
REPORTS_DIR      ?= reports
ORCH_BIN         ?= orchestrator/bin/bench
LOCAL_COMPOSE    ?= infra/local/docker-compose.yaml
# Local mode env file: prefer the operator-edited copy, fall back to
# the checked-in example so a fresh `git clone` works without setup.
LOCAL_ENV_FILE   ?= $(shell test -f infra/local/.env && echo infra/local/.env || echo infra/local/.env.example)
# Active profile inside the local stack — drives which gateways/<gw>/<profile>/
# nginx.conf gets bind-mounted into the gateway container.
GATEWAY_PROFILE  ?= p01-vanilla
# Active gateway "name" tag (used by parity-attestation + load-gateway as a
# pure label, not as routing — the routing comes from LOCAL_COMPOSE).
LOCAL_GATEWAY    ?= local-stack
AWS_TOFU_DIR     ?= infra/aws

# --- Backend (Phase 2) ------------------------------------------------------
# Pinned upstream: github.com/mccutchen/go-httpbin @ v2.22.1
BACKEND_IMAGE    ?= gateway-benchmarks/backend
BACKEND_VERSION  ?= v2.22.1
BACKEND_PORT     ?= 8080
# Empty default => docker builds for the host's native arch (fast on Mac).
# Override to `linux/amd64` for CI / AWS runs: `make backend-build BACKEND_PLATFORM=linux/amd64`.
BACKEND_PLATFORM ?=
BUILD_DATE       := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
help: ## Show this help
	@echo "$(CYAN)Gateway Benchmarks — Makefile targets$(NC)"
	@echo ""
	@echo "$(YELLOW)General:$(NC)"
	@echo "  $(GREEN)help$(NC)                  Show this message"
	@echo "  $(GREEN)prereqs-check$(NC)         Verify Docker, Go, k6, jq, tofu"
	@echo "  $(GREEN)lint$(NC)                  shellcheck for scripts/, go vet for orchestrator/"
	@echo ""
	@echo "$(YELLOW)Backend (Phase 2):$(NC)"
	@echo "  $(GREEN)backend-build$(NC)         Build the vendored go-httpbin container (native arch)"
	@echo "  $(GREEN)backend-build-amd64$(NC)   Build explicitly for linux/amd64 (CI / AWS)"
	@echo "  $(GREEN)backend-run$(NC)           Run the backend locally on :$(BACKEND_PORT)"
	@echo "  $(GREEN)backend-smoke$(NC)         Hit the backend's smoke endpoints (requires running instance)"
	@echo ""
	@echo "$(YELLOW)Orchestrator (Phase 6):$(NC)"
	@echo "  $(GREEN)orchestrator-build$(NC)    go build -> $(ORCH_BIN)"
	@echo "  $(GREEN)orchestrator-vet$(NC)      go vet ./orchestrator/..."
	@echo "  $(GREEN)orchestrator-test$(NC)     go test -race ./orchestrator/..."
	@echo "  $(GREEN)bench-run$(NC)             End-to-end (parity → load → aggregate → manifest)"
	@echo "  $(GREEN)bench-validate$(NC)        Parity-only sweep across BENCH_GATEWAYS × BENCH_POLICIES"
	@echo "  $(GREEN)bench-aggregate$(NC)       Re-aggregate reports/\$$(BENCH_RUN_ID)/raw → matrix.csv + cells.jsonl + matrix.md"
	@echo "  $(GREEN)bench-manifest$(NC)        Print manifest.json of the latest (or specific) run"
	@echo "  $(GREEN)bench-version$(NC)         Print bench binary version + build metadata"
	@echo "  $(GREEN)bench-report$(NC)          Render reports/\$$(BENCH_RUN_ID)/report.html (Phase 7)"
	@echo "  $(GREEN)bench-compare-runs$(NC)    Diff two runs against the tolerance table (Phase 8)"
	@echo ""
	@echo "$(YELLOW)Local mode (Phase 5):$(NC)"
	@echo "  $(GREEN)perf-local-up$(NC)             Bring up loadgen+gateway+backend on 2 isolated bridge networks"
	@echo "  $(GREEN)perf-local-parity$(NC)         Parity-check the running stack against http://localhost:9080"
	@echo "  $(GREEN)perf-local-cycle-smoke$(NC)    End-to-end smoke: s01 on :9080 + s13 on :9443 (if profile serves TLS)"
	@echo "  $(GREEN)perf-local-down$(NC)           Stop and remove the local stack"
	@echo "  $(GREEN)perf-local-clean$(NC)          Delete the reports/local-smoke/ scratch directory"
	@echo "  $(GREEN)perf-local-run$(NC)            Drive the full matrix locally via bench (BENCH_GATEWAYS, BENCH_POLICIES, BENCH_LOADS)"
	@echo "  $(GREEN)perf-local-report$(NC)         Render HTML report for the latest local run (BENCH_RUN_ID overrides --latest)"
	@echo ""
	@echo "$(YELLOW)AWS mode (Phase 5 — 3 EC2 c6i.2xlarge in cluster PG):$(NC)"
	@echo "  $(GREEN)perf-aws-init$(NC)             $(TOFU_BIN) init in $(AWS_TOFU_DIR)/ (one-time per checkout)"
	@echo "  $(GREEN)perf-aws-up$(NC)               $(TOFU_BIN) apply — bring up loadgen + gateway + backend"
	@echo "  $(GREEN)perf-aws-summary$(NC)          Print cluster summary (IPs + ready-to-paste SSH commands)"
	@echo "  $(GREEN)perf-aws-ssh-loadgen$(NC)      SSH into the loadgen host"
	@echo "  $(GREEN)perf-aws-ssh-gateway$(NC)      SSH into the gateway host"
	@echo "  $(GREEN)perf-aws-ssh-backend$(NC)      SSH into the backend host"
	@echo "  $(GREEN)perf-aws-destroy$(NC)          $(TOFU_BIN) destroy — terminate everything"
	@echo "  $(GREEN)perf-aws-run$(NC)              Drive the AWS matrix via bench (set BENCH_TARGET_AWS=http://<gateway-ip>:9080)"
	@echo "  $(GREEN)perf-aws-report$(NC)           Render HTML report for the AWS run (BENCH_RUN_ID overrides --latest)"
	@echo "  $(GREEN)perf-aws-full-report$(NC)      One command: deploy AWS, run canonical matrix with progress, copy/open report.html"
	@echo ""
	@echo "$(YELLOW)Quality (Phase 3):$(NC)"
	@echo "  $(GREEN)parity-check$(NC)          Run parity for a single profile against a live target"
	@echo "  $(GREEN)parity-check-all$(NC)      Sweep parity across all 12 profiles against PARITY_TARGET"
	@echo "  $(GREEN)parity-gateway$(NC)        End-to-end: bring up <PARITY_GATEWAY>, run one profile, tear down"
	@echo "  $(GREEN)parity-gateway-all$(NC)    End-to-end sweep of p01…p12 against <PARITY_GATEWAY>"
	@echo ""
	@echo "$(YELLOW)Load (Phase 4):$(NC)"
	@echo "  $(GREEN)load-gateway$(NC)              Single load cell end-to-end (compose up → parity → k6 → tear down)"
	@echo "  $(GREEN)load-gateway-load-sweep$(NC)   Sweep all 4 load profiles for one (LOAD_GATEWAY × LOAD_POLICY × LOAD_SCENARIO)"
	@echo "  $(GREEN)load-sweep$(NC)                Matrix sweep (LOAD_GATEWAY × LOAD_POLICIES × LOAD_LOADS via orchestrator)"
	@echo "  Aggregate / cross-run / HTML render → use 'bench aggregate', 'bench compare-runs', 'bench report'"
	@echo ""
	@echo "$(CYAN)Run ID:$(NC) $(RUN_ID)"
	@echo "$(CYAN)See:$(NC)    README.md · TASK.md · CHANGELOG.md"

# ---------------------------------------------------------------------------
# prereqs
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Hidden preflight: refuse to boot a second bench stack when one is already
# running. Every target that invokes `docker compose up` on either
# infra/local/ or gateways/<gw>/ takes this as a prerequisite, so the
# operator gets an actionable message ("run `make perf-local-down`") instead
# of the raw `Bind for 0.0.0.0:9080 failed: port is already allocated`.
# Override per-invocation with BENCH_SKIP_PORTS_CHECK=1 (useful for CI paths
# that already know the host is clean).
# ---------------------------------------------------------------------------
.bench-ports-free:
	@bash scripts/bench-ports-free.sh

prereqs-check: ## Verify the local environment
	@echo "$(YELLOW)Checking prerequisites...$(NC)"
	@command -v docker  >/dev/null 2>&1 || { echo "$(RED)✗ docker not found$(NC)";  exit 2; }
	@command -v go      >/dev/null 2>&1 || { echo "$(RED)✗ go not found$(NC)";       exit 2; }
	@command -v jq      >/dev/null 2>&1 || { echo "$(RED)✗ jq not found$(NC)";       exit 2; }
	@docker compose version >/dev/null 2>&1 || { echo "$(RED)✗ docker compose plugin not found$(NC)"; exit 2; }
	@echo "$(GREEN)✓ docker         $$(docker --version  | awk '{print $$3}' | tr -d ',')$(NC)"
	@echo "$(GREEN)✓ docker compose $$(docker compose version --short)$(NC)"
	@echo "$(GREEN)✓ go             $$(go version | awk '{print $$3}')$(NC)"
	@echo "$(GREEN)✓ jq             $$(jq --version)$(NC)"
	@command -v tofu >/dev/null 2>&1 && echo "$(GREEN)✓ tofu           $$(tofu version | head -1 | awk '{print $$2}')$(NC)" || echo "$(YELLOW)… tofu not installed (only needed for perf-aws-*)$(NC)"
	@command -v k6 >/dev/null 2>&1   && echo "$(GREEN)✓ k6             $$(k6 version | awk '{print $$2}')$(NC)"            || echo "$(YELLOW)… k6 not installed (the containerised version is used)$(NC)"
	@echo "$(GREEN)========================================$(NC)"
	@echo "$(GREEN)RESULT: PASS$(NC)"
	@echo "$(GREEN)========================================$(NC)"

# ---------------------------------------------------------------------------
# lint
# ---------------------------------------------------------------------------
lint: ## Lint shell and Go code
	@echo "$(YELLOW)Running shellcheck...$(NC)"
	@if command -v shellcheck >/dev/null 2>&1; then \
		find scripts -name '*.sh' -print0 2>/dev/null | xargs -0 -r shellcheck --severity=warning || exit 1; \
		echo "$(GREEN)✓ shellcheck passed$(NC)"; \
	else \
		echo "$(YELLOW)… shellcheck not installed, skipping$(NC)"; \
	fi
	@echo "$(YELLOW)Running go vet...$(NC)"
	@if [ -f orchestrator/go.mod ]; then \
		cd orchestrator && go vet ./... && echo "$(GREEN)✓ go vet passed$(NC)"; \
	else \
		echo "$(YELLOW)… orchestrator/go.mod is absent, go vet skipped$(NC)"; \
	fi

# ---------------------------------------------------------------------------
# Backend (Phase 2)
# ---------------------------------------------------------------------------
backend-build: ## Build the backend image ($(BACKEND_IMAGE):$(BACKEND_VERSION))
	@if [ -n "$(BACKEND_PLATFORM)" ]; then \
		echo "$(YELLOW)Building $(BACKEND_IMAGE):$(BACKEND_VERSION) for $(BACKEND_PLATFORM)...$(NC)"; \
		docker buildx build \
			--platform $(BACKEND_PLATFORM) \
			--build-arg BUILD_DATE=$(BUILD_DATE) \
			--tag  $(BACKEND_IMAGE):$(BACKEND_VERSION) \
			--tag  $(BACKEND_IMAGE):latest \
			--load \
			backend/ ; \
	else \
		echo "$(YELLOW)Building $(BACKEND_IMAGE):$(BACKEND_VERSION) for native arch...$(NC)"; \
		docker build \
			--build-arg BUILD_DATE=$(BUILD_DATE) \
			--tag  $(BACKEND_IMAGE):$(BACKEND_VERSION) \
			--tag  $(BACKEND_IMAGE):latest \
			backend/ ; \
	fi
	@echo "$(GREEN)✓ built:$(NC) $(BACKEND_IMAGE):$(BACKEND_VERSION)"
	@docker image inspect $(BACKEND_IMAGE):$(BACKEND_VERSION) \
		--format 'arch:  {{.Architecture}}{{"\n"}}size:  {{.Size}} bytes' 2>/dev/null || true

backend-build-amd64: ## Build the backend image explicitly for linux/amd64 (used by AWS / CI)
	@$(MAKE) backend-build BACKEND_PLATFORM=linux/amd64

backend-run: ## Run the backend locally on :$(BACKEND_PORT)
	@echo "$(YELLOW)Starting $(BACKEND_IMAGE):$(BACKEND_VERSION) on :$(BACKEND_PORT)...$(NC)"
	@docker run --rm -it \
		--name gateway-benchmarks-backend \
		-p $(BACKEND_PORT):8080 \
		$(BACKEND_IMAGE):$(BACKEND_VERSION)

backend-smoke: ## Smoke-test a running backend (expects :$(BACKEND_PORT) reachable)
	@echo "$(YELLOW)Smoke-testing backend on http://localhost:$(BACKEND_PORT)...$(NC)"
	@bash scripts/backend-smoke.sh $(BACKEND_PORT)

# ---------------------------------------------------------------------------
# Orchestrator (Phase 6)
# ---------------------------------------------------------------------------
ORCH_VERSION   ?= dev
ORCH_BUILDTIME := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
ORCH_GIT_SHA   := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
ORCH_GIT_DIRTY := $(shell test -n "$$(git status --porcelain 2>/dev/null)" && echo true || echo false)
ORCH_PKG       := github.com/wallarm/gateway-benchmarks/orchestrator/internal/version
ORCH_LDFLAGS   := -s -w \
	-X $(ORCH_PKG).Version=$(ORCH_VERSION) \
	-X $(ORCH_PKG).GitSHA=$(ORCH_GIT_SHA) \
	-X $(ORCH_PKG).GitDirty=$(ORCH_GIT_DIRTY) \
	-X $(ORCH_PKG).BuildTime=$(ORCH_BUILDTIME)

orchestrator-build: ## Build the Go orchestrator into $(ORCH_BIN)
	@echo "$(YELLOW)Building orchestrator (version=$(ORCH_VERSION) sha=$(ORCH_GIT_SHA))$(NC)"
	@if [ ! -f orchestrator/go.mod ]; then \
		echo "$(RED)… orchestrator/go.mod missing$(NC)"; \
		exit 1; \
	fi
	@mkdir -p $(dir $(ORCH_BIN))
	@cd orchestrator && go build -trimpath -ldflags="$(ORCH_LDFLAGS)" -o ../$(ORCH_BIN) .
	@echo "$(GREEN)✓ orchestrator built: $(ORCH_BIN)$(NC)"

orchestrator-vet: ## go vet ./orchestrator/...
	@cd orchestrator && go vet ./...
	@echo "$(GREEN)✓ go vet clean$(NC)"

orchestrator-test: ## go test ./orchestrator/... (race + coverage)
	@cd orchestrator && go test -race -count=1 ./...
	@echo "$(GREEN)✓ go test ok$(NC)"

# --- bench (Phase 6) convenience wrappers ----------------------------------
# Tunable via env vars: BENCH_GATEWAYS, BENCH_POLICIES, BENCH_LOADS, BENCH_TARGET,
# BENCH_SEED, BENCH_RUN_ID, BENCH_REPS, BENCH_NOTES, BENCH_MODE, BENCH_VERBOSE, BENCH_QUIET.
BENCH_GATEWAYS ?= nginx
BENCH_POLICIES ?= p01-vanilla
BENCH_LOADS    ?= p1-baseline
BENCH_TARGET   ?= http://localhost:9080
BENCH_SEED     ?= 42
BENCH_RUN_ID   ?= $(RUN_ID)
BENCH_REPS     ?= 1
BENCH_NOTES    ?=
BENCH_MODE     ?= local
BENCH_VERBOSE  ?= 0
BENCH_QUIET    ?= 0
BENCH_VERBOSE_FLAG := $(if $(filter 1 true TRUE yes YES,$(BENCH_VERBOSE)),--verbose,)
BENCH_QUIET_FLAG   := $(if $(filter 1 true TRUE yes YES,$(BENCH_QUIET)),--quiet,)

bench-run: .bench-ports-free orchestrator-build ## Run the orchestrator end-to-end (parity → load → aggregate → manifest)
	@$(ORCH_BIN) --repo-root "$(CURDIR)" --run-id $(BENCH_RUN_ID) run \
		$(BENCH_VERBOSE_FLAG) \
		$(BENCH_QUIET_FLAG) \
		--gateways "$(BENCH_GATEWAYS)" \
		--policies "$(BENCH_POLICIES)" \
		--loads    "$(BENCH_LOADS)" \
		--seed     $(BENCH_SEED) \
		--reps     $(BENCH_REPS) \
		--mode     $(BENCH_MODE) \
		--target   "$(BENCH_TARGET)" \
		$(if $(BENCH_NOTES),--notes "$(BENCH_NOTES)",)

bench-validate: .bench-ports-free orchestrator-build ## Run parity-only across BENCH_GATEWAYS × BENCH_POLICIES
	@$(ORCH_BIN) --repo-root "$(CURDIR)" \
		$(BENCH_VERBOSE_FLAG) \
		$(BENCH_QUIET_FLAG) \
		validate \
		--gateways "$(BENCH_GATEWAYS)" \
		--policies "$(BENCH_POLICIES)" \
		--target   "$(BENCH_TARGET)" \
		--run-id   $(BENCH_RUN_ID)

bench-aggregate: orchestrator-build ## Re-aggregate reports/$(BENCH_RUN_ID)/raw/ into matrix.csv + cells.jsonl + matrix.md
	@$(ORCH_BIN) --repo-root "$(CURDIR)" aggregate --run-id $(BENCH_RUN_ID)

bench-manifest: orchestrator-build ## Print manifest.json of the latest run (or BENCH_RUN_ID if set)
	@if [ -n "$(BENCH_RUN_ID)" ] && [ -d reports/$(BENCH_RUN_ID) ]; then \
		$(ORCH_BIN) --repo-root "$(CURDIR)" manifest --run-id $(BENCH_RUN_ID); \
	else \
		$(ORCH_BIN) --repo-root "$(CURDIR)" manifest; \
	fi

bench-version: orchestrator-build ## Print the bench binary version + build metadata
	@$(ORCH_BIN) version

# Render the canonical HTML report from cells.jsonl + manifest.json.
# Combine multiple runs by passing BENCH_REPORT_COMBINE="run-a,run-b,run-c".
# Optional knobs:
#   BENCH_REPORT_TITLE  — page title (defaults to "API Gateway Benchmark — <run-id>")
#   BENCH_REPORT_ENV    — single-line environment annotation under the hero
BENCH_REPORT_COMBINE ?=
BENCH_REPORT_TITLE   ?=
BENCH_REPORT_ENV     ?=
bench-report: orchestrator-build ## Render reports/$(BENCH_RUN_ID)/report.html (Phase 7)
	@if [ -n "$(BENCH_REPORT_COMBINE)" ]; then \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report \
			--combined "$(BENCH_REPORT_COMBINE)" \
			$(if $(BENCH_REPORT_TITLE),--title "$(BENCH_REPORT_TITLE)",) \
			$(if $(BENCH_REPORT_ENV),--env "$(BENCH_REPORT_ENV)",); \
	elif [ -n "$(BENCH_RUN_ID)" ] && [ -d reports/$(BENCH_RUN_ID) ]; then \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --run-id $(BENCH_RUN_ID) \
			$(if $(BENCH_REPORT_TITLE),--title "$(BENCH_REPORT_TITLE)",) \
			$(if $(BENCH_REPORT_ENV),--env "$(BENCH_REPORT_ENV)",); \
	else \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --latest \
			$(if $(BENCH_REPORT_TITLE),--title "$(BENCH_REPORT_TITLE)",) \
			$(if $(BENCH_REPORT_ENV),--env "$(BENCH_REPORT_ENV)",); \
	fi

# Phase 8 — reproducibility gate. Compare two bench runs against the
# canonical tolerance table (RPS ±3 %, latency p50/p95/p99 ±10 %,
# mem ±5 %, CPU ±10 %; 5xx / 4xx_expected must match). Exit codes:
#   0 REPRODUCIBLE | 1 SOFT DIFF | 2 NOT REPRODUCIBLE
BENCH_COMPARE_A    ?=
BENCH_COMPARE_B    ?=
BENCH_COMPARE_ARGS ?=
bench-compare-runs: orchestrator-build ## Diff two runs (BENCH_COMPARE_A / BENCH_COMPARE_B) against the tolerance table
	@if [ -z "$(BENCH_COMPARE_A)" ] || [ -z "$(BENCH_COMPARE_B)" ]; then \
		echo "$(RED)BENCH_COMPARE_A and BENCH_COMPARE_B must be set$(NC)"; \
		echo "  example: make bench-compare-runs BENCH_COMPARE_A=run-1 BENCH_COMPARE_B=run-2"; \
		exit 64; \
	fi
	@$(ORCH_BIN) --repo-root "$(CURDIR)" compare-runs \
		"$(BENCH_COMPARE_A)" "$(BENCH_COMPARE_B)" $(BENCH_COMPARE_ARGS)

# ---------------------------------------------------------------------------
# Local mode (Phase 5 + 6)
# ---------------------------------------------------------------------------
perf-local-up: .bench-ports-free ## Bring up the local 3-host stack (loadgen+gateway+backend on 2 isolated nets)
	@echo "$(YELLOW)perf-local-up: starting 3-host topology$(NC)"
	@echo "  compose : $(LOCAL_COMPOSE)"
	@echo "  env-file: $(LOCAL_ENV_FILE)"
	@echo "  profile : $(GATEWAY_PROFILE)"
	@mkdir -p reports/local-smoke
	@GATEWAY_PROFILE=$(GATEWAY_PROFILE) docker compose -f $(LOCAL_COMPOSE) --env-file $(LOCAL_ENV_FILE) up -d
	@echo "$(YELLOW)Waiting for gateway data plane on http://localhost:9080…$(NC)"
	@for i in $$(seq 1 30); do \
		if curl -fsS -o /dev/null --max-time 1 http://localhost:9080/status/200 2>/dev/null; then \
			echo "$(GREEN)✓ gateway answered after $$i attempts$(NC)"; \
			break; \
		fi; \
		if [ $$i -eq 30 ]; then \
			echo "$(RED)✗ gateway never answered after 30 tries (15s)$(NC)"; \
			docker compose -f $(LOCAL_COMPOSE) --env-file $(LOCAL_ENV_FILE) logs --tail=40; \
			exit 1; \
		fi; \
		sleep 0.5; \
	done
	@echo "$(GREEN)✓ stack up$(NC)"
	@echo "  HTTP : http://localhost:9080  (parity + s01..s12)"
	@echo "  HTTPS: https://localhost:9443 (s13/s14, on p01-vanilla & p12-full-pipeline)"

perf-local-parity: ## Parity-check the running local stack against PARITY_TARGET (default localhost:9080)
	@echo "$(YELLOW)perf-local-parity: $(GATEWAY_PROFILE) against http://localhost:9080$(NC)"
	@PARITY_GATEWAY=$(LOCAL_GATEWAY) PARITY_TARGET=http://localhost:9080 PARITY_PROFILE=$(GATEWAY_PROFILE) \
		$(MAKE) parity-check

perf-local-cycle-smoke: ## End-to-end smoke (s01 over :9080 + s13 over :9443 if profile serves TLS)
	@echo "$(YELLOW)perf-local-cycle-smoke: HTTP + HTTPS round-trip via the local stack$(NC)"
	@GATEWAY_PROFILE=$(GATEWAY_PROFILE) GATEWAY_NAME=$(LOCAL_GATEWAY) \
		bash scripts/perf-local-cycle-smoke.sh

perf-local-run: .bench-ports-free orchestrator-build ## Drive the full matrix locally via bench (parity + load + aggregate)
	@$(ORCH_BIN) --repo-root "$(CURDIR)" --run-id $(BENCH_RUN_ID) run \
		$(BENCH_VERBOSE_FLAG) \
		$(BENCH_QUIET_FLAG) \
		--gateways "$(BENCH_GATEWAYS)" \
		--policies "$(BENCH_POLICIES)" \
		--loads    "$(BENCH_LOADS)" \
		--seed     $(BENCH_SEED) \
		--reps     $(BENCH_REPS) \
		--mode     local \
		--target   "$(BENCH_TARGET)" \
		$(if $(BENCH_NOTES),--notes "$(BENCH_NOTES)",)

perf-local-report: orchestrator-build ## Render HTML report for the most recent local run (BENCH_RUN_ID overrides)
	@if [ -n "$(BENCH_RUN_ID)" ] && [ -d reports/$(BENCH_RUN_ID) ]; then \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --run-id $(BENCH_RUN_ID); \
	else \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --latest; \
	fi

perf-local-down: ## Stop and remove the smoke stack + any orphan per-cell stacks (gwb-*)
	@echo "$(YELLOW)perf-local-down: tearing down local stack$(NC)"
	@docker compose -f $(LOCAL_COMPOSE) --env-file $(LOCAL_ENV_FILE) down --remove-orphans -v
	@bash scripts/bench-down-orphans.sh
	@echo "$(GREEN)✓ stack down$(NC)"

perf-local-clean: ## Delete the local-smoke output directory (reports/local-smoke/)
	@echo "$(YELLOW)perf-local-clean: removing reports/local-smoke/$(NC)"
	@rm -rf reports/local-smoke
	@echo "$(GREEN)✓ scratch files removed$(NC)"

# ---------------------------------------------------------------------------
# AWS mode (Phase 5 — infrastructure, Phase 6 — orchestrator wiring)
# ---------------------------------------------------------------------------
# Tooling auto-detection: prefer OpenTofu (open-source, BSL-free), fall
# back to terraform if it's the only one installed. Operator can pin via
# `make perf-aws-up TOFU_BIN=terraform`.
TOFU_BIN ?= $(shell command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)

# One-command AWS report runner. Defaults to a larger instance class than the
# canonical c6i.2xlarge so the loadgen/gateway have headroom; the fixed-duration
# k6 profiles still dominate elapsed time unless the matrix is sharded.
BENCH_AWS_FULL_RUN_ID      ?= aws-$(RUN_ID)
BENCH_AWS_FULL_GATEWAYS    ?= all
BENCH_AWS_FULL_LOADS       ?= http
BENCH_AWS_FULL_REPS        ?= 5
BENCH_AWS_FULL_NOTES       ?= AWS canonical report sweep
BENCH_AWS_INSTANCE_TYPE    ?= c7i.4xlarge
BENCH_AWS_FLEET_SIZE       ?= 7
BENCH_AWS_PARALLEL         ?= 4
BENCH_AWS_REPORT_COPY_DIR  ?= $(HOME)/Desktop/$(BENCH_AWS_FULL_RUN_ID)
BENCH_AWS_OPEN_REPORT      ?= 1
BENCH_AWS_DESTROY_AFTER    ?= 1
BENCH_PROGRESS_INTERVAL    ?= 30s
BENCH_AWS_REMOTE_BIN       ?= orchestrator/bin/bench-linux-amd64
# Per-cell warmup before measurement: primes JIT, connection pools, page cache.
# Overrides aws-clean-cell.sh defaults; set 0 to skip the warmup entirely.
BENCH_WARMUP_DURATION      ?= 30
BENCH_WARMUP_VUS           ?= 50

perf-aws-init: ## tofu init in $(AWS_TOFU_DIR)/
	@echo "$(YELLOW)perf-aws-init: $(TOFU_BIN) init in $(AWS_TOFU_DIR)/$(NC)"
	@cd $(AWS_TOFU_DIR) && $(TOFU_BIN) init

perf-aws-up: ## tofu apply — bring up 3 EC2 c6i.2xlarge in cluster placement group
	@echo "$(YELLOW)perf-aws-up: $(TOFU_BIN) apply in $(AWS_TOFU_DIR)/$(NC)"
	@if [ ! -f $(AWS_TOFU_DIR)/terraform.tfvars ]; then \
		echo "$(RED)✗ infra/aws/terraform.tfvars is missing.$(NC)"; \
		echo "  Copy infra/aws/terraform.tfvars.example, edit ssh_key_name + allowed_ssh_cidrs,"; \
		echo "  then re-run 'make perf-aws-up'."; \
		exit 2; \
	fi
	@cd $(AWS_TOFU_DIR) && $(TOFU_BIN) apply -auto-approve
	@echo "$(GREEN)✓ AWS stack up$(NC)"
	@$(MAKE) perf-aws-summary

perf-aws-deploy: perf-aws-up ## Alias for perf-aws-up (kept for backward compat)

perf-aws-summary: ## Print the cluster summary (IPs + SSH commands)
	@cd $(AWS_TOFU_DIR) && $(TOFU_BIN) output -raw summary

perf-aws-ssh-loadgen: ## SSH into the loadgen host
	@cd $(AWS_TOFU_DIR) && $$($(TOFU_BIN) output -raw ssh_loadgen)

perf-aws-ssh-gateway: ## SSH into the gateway host
	@cd $(AWS_TOFU_DIR) && $$($(TOFU_BIN) output -raw ssh_gateway)

perf-aws-ssh-backend: ## SSH into the backend host
	@cd $(AWS_TOFU_DIR) && $$($(TOFU_BIN) output -raw ssh_backend)

perf-aws-run: orchestrator-build ## Drive the matrix on the AWS cluster via bench (parity + load + aggregate)
	@if [ -z "$(BENCH_TARGET_AWS)" ]; then \
		echo "$(RED)BENCH_TARGET_AWS is required (e.g. http://10.0.1.20:9080 — the gateway's private IP)$(NC)"; \
		exit 2; \
	fi
	@$(ORCH_BIN) --repo-root "$(CURDIR)" --run-id $(BENCH_RUN_ID) run \
		$(BENCH_VERBOSE_FLAG) \
		$(BENCH_QUIET_FLAG) \
		--gateways "$(BENCH_GATEWAYS)" \
		--policies "$(BENCH_POLICIES)" \
		--loads    "$(BENCH_LOADS)" \
		--seed     $(BENCH_SEED) \
		--reps     $(BENCH_REPS) \
		--mode     aws \
		--target   "$(BENCH_TARGET_AWS)" \
		$(if $(BENCH_NOTES),--notes "$(BENCH_NOTES)",)

perf-aws-report: orchestrator-build ## Render the canonical HTML report for an AWS run (BENCH_RUN_ID overrides --latest)
	@if [ -n "$(BENCH_RUN_ID)" ] && [ -d reports/$(BENCH_RUN_ID) ]; then \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --run-id $(BENCH_RUN_ID); \
	else \
		$(ORCH_BIN) --repo-root "$(CURDIR)" report --latest; \
	fi

perf-aws-full-report: orchestrator-build ## One command: deploy AWS, run canonical matrix with progress, copy/open report.html
	@BENCH_AWS_FULL_RUN_ID="$(BENCH_AWS_FULL_RUN_ID)" \
	AWS_TOFU_DIR="$(AWS_TOFU_DIR)" \
	TOFU_BIN="$(TOFU_BIN)" \
	ORCH_BIN="$(ORCH_BIN)" \
	BENCH_AWS_FULL_GATEWAYS="$(BENCH_AWS_FULL_GATEWAYS)" \
	BENCH_AWS_FULL_LOADS="$(BENCH_AWS_FULL_LOADS)" \
	BENCH_AWS_FULL_REPS="$(BENCH_AWS_FULL_REPS)" \
	BENCH_AWS_FULL_NOTES="$(BENCH_AWS_FULL_NOTES)" \
	BENCH_AWS_INSTANCE_TYPE="$(BENCH_AWS_INSTANCE_TYPE)" \
	BENCH_AWS_FLEET_SIZE="$(BENCH_AWS_FLEET_SIZE)" \
	BENCH_AWS_PARALLEL="$(BENCH_AWS_PARALLEL)" \
	BENCH_AWS_REPORT_COPY_DIR="$(BENCH_AWS_REPORT_COPY_DIR)" \
	BENCH_AWS_OPEN_REPORT="$(BENCH_AWS_OPEN_REPORT)" \
	BENCH_AWS_DESTROY_AFTER="$(BENCH_AWS_DESTROY_AFTER)" \
	BENCH_PROGRESS_INTERVAL="$(BENCH_PROGRESS_INTERVAL)" \
	BENCH_AWS_REMOTE_BIN="$(BENCH_AWS_REMOTE_BIN)" \
	BENCH_SEED="$(BENCH_SEED)" \
	BENCH_WARMUP_DURATION="$(BENCH_WARMUP_DURATION)" \
	BENCH_WARMUP_VUS="$(BENCH_WARMUP_VUS)" \
	WALLARM_IMAGE="$${WALLARM_IMAGE}" \
	GATEWAY_IMAGE="$${GATEWAY_IMAGE}" \
	BENCH_AWS_REPORT_S3_BUCKET="$${BENCH_AWS_REPORT_S3_BUCKET}" \
	BENCH_AWS_REPORT_S3_REGION="$${BENCH_AWS_REPORT_S3_REGION}" \
	BENCH_AWS_REPORT_S3_PREFIX="$${BENCH_AWS_REPORT_S3_PREFIX}" \
		bash scripts/perf-aws-full-report.sh

perf-aws-destroy: ## tofu destroy — terminate the 3 EC2 hosts and free all resources
	@echo "$(YELLOW)perf-aws-destroy: $(TOFU_BIN) destroy in $(AWS_TOFU_DIR)/$(NC)"
	@cd $(AWS_TOFU_DIR) && $(TOFU_BIN) destroy -auto-approve
	@echo "$(GREEN)✓ AWS stack destroyed$(NC)"

perf-aws-down: perf-aws-destroy ## Alias for perf-aws-destroy (kept for backward compat)

# ---------------------------------------------------------------------------
# Parity (Phase 3)
# ---------------------------------------------------------------------------
PARITY_GATEWAY ?= backend-direct
PARITY_TARGET  ?= http://localhost:$(BACKEND_PORT)
PARITY_PROFILE ?= p01-vanilla
PARITY_OUT     ?= reports/$(RUN_ID)/parity

parity-check: ## Run parity against a running target (see PARITY_* variables)
	@echo "$(YELLOW)parity: gateway=$(PARITY_GATEWAY) profile=$(PARITY_PROFILE) target=$(PARITY_TARGET)$(NC)"
	@mkdir -p $(PARITY_OUT)
	@bash scripts/parity-attestation.sh \
		--gateway $(PARITY_GATEWAY) \
		--profile $(PARITY_PROFILE) \
		--target  $(PARITY_TARGET) \
		--output  $(PARITY_OUT)/$(PARITY_GATEWAY)-$(PARITY_PROFILE).json \
		--verbose

parity-check-all: ## Run parity across every profile p01..p12 against PARITY_TARGET
	@echo "$(YELLOW)parity: sweeping p01..p12 against $(PARITY_TARGET)$(NC)"
	@mkdir -p $(PARITY_OUT)
	@set -e; \
	 passed=0; failed=0; \
	 for p in p01-vanilla p02-jwt p03-jwks-rs256-basic \
	          p04-rl-static p05-rl-endpoint \
	          p06-rl-dynamic-low p07-rl-dynamic-high \
	          p08-req-headers p09-resp-headers \
	          p10-req-body p11-resp-body p12-full-pipeline; do \
	     rc=0; \
	     bash scripts/parity-attestation.sh \
	         --gateway $(PARITY_GATEWAY) \
	         --profile $$p \
	         --target  $(PARITY_TARGET) \
	         --output  $(PARITY_OUT)/$(PARITY_GATEWAY)-$$p.json \
	         > /dev/null 2>&1 || rc=$$?; \
	     st=$$(jq -r '.status' $(PARITY_OUT)/$(PARITY_GATEWAY)-$$p.json); \
	     ps=$$(jq -r '.passed' $(PARITY_OUT)/$(PARITY_GATEWAY)-$$p.json); \
	     tot=$$(jq -r '.probes' $(PARITY_OUT)/$(PARITY_GATEWAY)-$$p.json); \
	     sk=$$(jq -r '.skipped' $(PARITY_OUT)/$(PARITY_GATEWAY)-$$p.json); \
	     printf '  %-22s  %-6s  %2s/%-2s  skipped=%s\n' "$$p" "$$st" "$$ps" "$$tot" "$$sk"; \
	     if [ "$$st" = "PASS" ]; then passed=$$((passed+1)); else failed=$$((failed+1)); fi; \
	 done; \
	 echo ""; \
	 echo "$(CYAN)Summary:$(NC) $$passed passed, $$failed not-PASS (reports in $(PARITY_OUT)/)"

# ---------------------------------------------------------------------------
# Parity (Phase 3b): bring up a single gateway, run one profile, tear down.
#
# This differs from `parity-check` above: `parity-check` assumes the
# target is already running (cheap, fast), while `parity-gateway`
# drives the full lifecycle:
#    docker compose up -> setup.sh -> parity -> docker compose down.
#
# Override PARITY_GATEWAY / PARITY_PROFILE on the command line:
#   make parity-gateway PARITY_GATEWAY=wallarm PARITY_PROFILE=p01-vanilla
# ---------------------------------------------------------------------------
PARITY_RUN_ID ?= $(RUN_ID)

parity-gateway: .bench-ports-free ## Bring up <PARITY_GATEWAY>, run <PARITY_PROFILE>, tear down
	@RUN_ID=$(PARITY_RUN_ID) bash scripts/parity-gateway.sh \
		--gateway $(PARITY_GATEWAY) \
		--profile $(PARITY_PROFILE) \
		--output  reports/$(PARITY_RUN_ID)/parity/$(PARITY_GATEWAY)-$(PARITY_PROFILE).json \
		--verbose

parity-gateway-all: .bench-ports-free ## Run every profile p01..p12 end-to-end against <PARITY_GATEWAY>
	@echo "$(YELLOW)parity-gateway: sweeping p01..p12 against $(PARITY_GATEWAY)$(NC)"
	@mkdir -p reports/$(PARITY_RUN_ID)/parity
	@passed=0; failed=0; missing=0; \
	 for p in p01-vanilla p02-jwt p03-jwks-rs256-basic \
	          p04-rl-static p05-rl-endpoint \
	          p06-rl-dynamic-low p07-rl-dynamic-high \
	          p08-req-headers p09-resp-headers \
	          p10-req-body p11-resp-body p12-full-pipeline; do \
	     out=reports/$(PARITY_RUN_ID)/parity/$(PARITY_GATEWAY)-$$p.json; \
	     if [ ! -d gateways/$(PARITY_GATEWAY)/$$p ]; then \
	         printf '  %-22s  %-16s  (directory missing — not yet implemented)\n' "$$p" "FEATURE-MISSING"; \
	         missing=$$((missing+1)); \
	         continue; \
	     fi; \
	     RUN_ID=$(PARITY_RUN_ID) bash scripts/parity-gateway.sh \
	         --gateway $(PARITY_GATEWAY) \
	         --profile $$p \
	         --output  $$out \
	         > /dev/null 2>&1 || true; \
	     st=$$(jq -r '.status // "UNKNOWN"' $$out 2>/dev/null); \
	     ps=$$(jq -r '.passed // 0'         $$out 2>/dev/null); \
	     tot=$$(jq -r '.probes // 0'        $$out 2>/dev/null); \
	     printf '  %-22s  %-16s  %2s/%-2s\n' "$$p" "$$st" "$$ps" "$$tot"; \
	     case "$$st" in \
	         PASS) passed=$$((passed+1));; \
	         FAIL) failed=$$((failed+1));; \
	         *)    missing=$$((missing+1));; \
	     esac; \
	 done; \
	 echo ""; \
	 echo "$(CYAN)Summary:$(NC) $$passed PASS, $$failed FAIL, $$missing other (reports in reports/$(PARITY_RUN_ID)/parity/)"

# ---------------------------------------------------------------------------
# Load (Phase 4): one (gateway, policy, scenario, load-profile) cell end-to-
# end. The runner script (scripts/load-gateway.sh) brings up the gateway,
# runs parity attestation as a precondition, fires k6 against the gateway
# inside its own bench-net, and tears the stack down on exit.
#
# Usage examples:
#   make load-gateway LOAD_GATEWAY=nginx LOAD_POLICY=p01-vanilla \
#                     LOAD_SCENARIO=s01-vanilla-http LOAD_PROFILE=p1-baseline
#
#   make load-gateway-load-sweep LOAD_GATEWAY=envoy LOAD_POLICY=p01-vanilla \
#                                LOAD_SCENARIO=s01-vanilla-http
# ---------------------------------------------------------------------------
LOAD_RUN_ID    ?= $(RUN_ID)
LOAD_GATEWAY   ?= nginx
LOAD_POLICY    ?= p01-vanilla
LOAD_SCENARIO  ?= s01-vanilla-http
LOAD_PROFILE   ?= p1-baseline
LOAD_SEED      ?= 42
LOAD_OPTS      ?=

load-gateway: .bench-ports-free ## Single load cell end-to-end (k6 against one gateway × policy × scenario × load profile)
	@RUN_ID=$(LOAD_RUN_ID) bash scripts/load-gateway.sh \
		--gateway  $(LOAD_GATEWAY) \
		--policy   $(LOAD_POLICY) \
		--scenario $(LOAD_SCENARIO) \
		--load     $(LOAD_PROFILE) \
		--seed     $(LOAD_SEED) \
		$(LOAD_OPTS)

load-gateway-load-sweep: .bench-ports-free ## Sweep all 4 load profiles for one (LOAD_GATEWAY, LOAD_POLICY, LOAD_SCENARIO)
	@echo "$(YELLOW)load-gateway-load-sweep: $(LOAD_GATEWAY) / $(LOAD_POLICY) / $(LOAD_SCENARIO) × {p1-baseline,p2-sustained,p3-ramp,p4-stress}$(NC)"
	@passed=0; excluded=0; failed=0; \
	 for lp in p1-baseline p2-sustained p3-ramp p4-stress; do \
	     out_dir=reports/$(LOAD_RUN_ID)/raw/$(LOAD_GATEWAY)/$(LOAD_POLICY)__$${lp}__$(LOAD_SCENARIO); \
	     RUN_ID=$(LOAD_RUN_ID) BENCH_LOCAL_REPORT=0 bash scripts/load-gateway.sh \
	         --gateway  $(LOAD_GATEWAY) \
	         --policy   $(LOAD_POLICY) \
	         --scenario $(LOAD_SCENARIO) \
	         --load     $$lp \
	         --seed     $(LOAD_SEED) \
	         $(LOAD_OPTS) \
	         > /dev/null 2>&1 && rc=0 || rc=$$?; \
	     summary=$$out_dir/k6-summary.json; \
	     excluded_marker=$$out_dir/excluded.json; \
	     if [ -s "$$excluded_marker" ]; then \
	         reason=$$(jq -r '.reason' "$$excluded_marker" 2>/dev/null); \
	         printf '  %-14s  %-9s  (%s)\n' "$$lp" "EXCLUDED" "$$reason"; \
	         excluded=$$((excluded+1)); \
	     elif [ -s "$$summary" ]; then \
	         reqs=$$(jq -r '.metrics.http_reqs.count // 0'                 "$$summary" 2>/dev/null); \
	         p95=$$( jq -r '.metrics.http_req_duration["p(95)"] // 0'      "$$summary" 2>/dev/null); \
	         printf '  %-14s  %-9s  reqs=%-7s  p95=%sms\n' "$$lp" "PASS" "$$reqs" "$$p95"; \
	         passed=$$((passed+1)); \
	     else \
	         printf '  %-14s  %-9s  (rc=%d, see %s/logs/k6.log)\n' "$$lp" "FAIL" "$$rc" "$$out_dir"; \
	         failed=$$((failed+1)); \
	     fi; \
	 done; \
	 if [ -x orchestrator/bin/bench ]; then \
	     orchestrator/bin/bench --repo-root "$$(pwd)" aggregate --run-id $(LOAD_RUN_ID) -q >/dev/null 2>&1 && \
	     orchestrator/bin/bench --repo-root "$$(pwd)" report    --run-id $(LOAD_RUN_ID)    >/dev/null 2>&1 && \
	     report_path="reports/$(LOAD_RUN_ID)/report.html" || report_path="(HTML render failed)"; \
	 else \
	     report_path="(orchestrator/bin/bench not built)"; \
	 fi; \
	 echo ""; \
	 echo "$(CYAN)Summary:$(NC) $$passed PASS, $$failed FAIL, $$excluded EXCLUDED"; \
	 echo "  raw:    reports/$(LOAD_RUN_ID)/raw/$(LOAD_GATEWAY)/"; \
	 echo "  report: $$report_path"

# ---------------------------------------------------------------------------
# Orchestrator + aggregator (Phase 4 "Путь A" shell pipeline).
# ---------------------------------------------------------------------------
LOAD_POLICIES  ?=
LOAD_LOADS     ?= p1-baseline
LOAD_STOP_ON_FAIL ?= 0

load-sweep: .bench-ports-free ## Full matrix sweep: LOAD_GATEWAY × LOAD_POLICIES (default=all 12) × LOAD_LOADS (default=p1-baseline)
	@orch_args="--gateway $(LOAD_GATEWAY) --loads $(LOAD_LOADS) --seed $(LOAD_SEED)"; \
	 if [ -n "$(LOAD_POLICIES)" ]; then orch_args="$$orch_args --policies $(LOAD_POLICIES)"; fi; \
	 if [ "$(LOAD_STOP_ON_FAIL)" = "1" ]; then orch_args="$$orch_args --stop-on-fail"; fi; \
	 if [ -n "$(LOAD_RUN_ID)" ]; then orch_args="$$orch_args --run-id $(LOAD_RUN_ID)"; fi; \
	 bash scripts/load-orchestrator.sh $$orch_args

# Aggregation, cross-run roll-up, and HTML rendering all live in the
# Go orchestrator now: `bench aggregate`, `bench compare-runs`,
# `bench report` (see orchestrator/README.md). The shell/Python
# precursors (aggregate-csv.sh, aggregate-multi-csv.sh,
# render-html-report.py) and their Makefile entry points
# (load-aggregate, load-combine, load-report) were removed in the
# legacy-cleanup pass after they were fully covered by the Go code.

