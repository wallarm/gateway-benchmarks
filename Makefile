.DEFAULT_GOAL := help
.PHONY: help prereqs-check lint \
	backend-build backend-build-amd64 backend-run backend-smoke \
	orchestrator-build orchestrator-test \
	perf-local-up perf-local-run perf-local-report perf-local-down perf-local-clean \
	perf-aws-init perf-aws-deploy perf-aws-run perf-aws-report perf-aws-down \
	parity-check parity-check-all parity-gateway parity-gateway-all \
	load-gateway load-gateway-load-sweep load-sweep load-aggregate load-combine load-report

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

# Placeholder until a phase delivers the real implementation.
PHASE_TODO = @echo "$(YELLOW)[TODO] $@ — see ROADMAP.md; will be implemented in the relevant phase.$(NC)"

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
	@echo "  $(GREEN)orchestrator-test$(NC)     go test ./orchestrator/..."
	@echo ""
	@echo "$(YELLOW)Local mode:$(NC)"
	@echo "  $(GREEN)perf-local-up$(NC)         Bring up loadgen+gateway+backend via docker compose"
	@echo "  $(GREEN)perf-local-run$(NC)        Run the full matrix (policy × load × gateway)"
	@echo "  $(GREEN)perf-local-report$(NC)     Produce HTML+CSV into $(REPORTS_DIR)/<run>/"
	@echo "  $(GREEN)perf-local-down$(NC)       Stop the docker compose stack"
	@echo "  $(GREEN)perf-local-clean$(NC)      Delete volumes, networks, and scratch files"
	@echo ""
	@echo "$(YELLOW)AWS mode (3 EC2 cluster PG):$(NC)"
	@echo "  $(GREEN)perf-aws-init$(NC)         tofu init in $(AWS_TOFU_DIR)/"
	@echo "  $(GREEN)perf-aws-deploy$(NC)       tofu apply + ssh-deploy the stack to 3 EC2"
	@echo "  $(GREEN)perf-aws-run$(NC)          Run the matrix on AWS"
	@echo "  $(GREEN)perf-aws-report$(NC)       Pull raw data and render the HTML report"
	@echo "  $(GREEN)perf-aws-down$(NC)         Destroy the EC2 hosts (enable_perf_test=false + tofu apply)"
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
	@echo "  $(GREEN)load-aggregate$(NC)            Aggregate reports/\$$(LOAD_RUN_ID)/ into wide CSV/TSV/MD"
	@echo "  $(GREEN)load-combine$(NC)              Combine N reports/<run-id>/ into one CSV (LOAD_RUN_IDS=id1,id2,…)"
	@echo "  $(GREEN)load-report$(NC)               Render Chart.js HTML report from a combined CSV (LOAD_REPORT_INPUT=, LOAD_REPORT_OUTPUT=)"
	@echo ""
	@echo "$(CYAN)Run ID:$(NC) $(RUN_ID)"
	@echo "$(CYAN)See:$(NC)    README.md · TASK.md · ROADMAP.md"

# ---------------------------------------------------------------------------
# prereqs
# ---------------------------------------------------------------------------
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
		find scripts -name '*.sh' -print0 2>/dev/null | xargs -0 -r shellcheck --severity=style || exit 1; \
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
orchestrator-build: ## Build the Go orchestrator
	@echo "$(YELLOW)Building orchestrator...$(NC)"
	@if [ ! -f orchestrator/go.mod ]; then \
		echo "$(YELLOW)… orchestrator is not initialised yet (Phase 6)$(NC)"; \
		exit 0; \
	fi
	@mkdir -p $(dir $(ORCH_BIN))
	@cd orchestrator && go build -trimpath -ldflags="-s -w" -o ../$(ORCH_BIN) ./cmd/bench
	@echo "$(GREEN)✓ orchestrator built: $(ORCH_BIN)$(NC)"

orchestrator-test:
	$(PHASE_TODO)

# ---------------------------------------------------------------------------
# Local mode (Phase 5 + 6)
# ---------------------------------------------------------------------------
perf-local-up: ## Bring up the local stack
	$(PHASE_TODO)

perf-local-run: ## Run the full matrix locally
	$(PHASE_TODO)

perf-local-report: ## Produce HTML+CSV
	$(PHASE_TODO)

perf-local-down: ## Stop the docker compose stack
	$(PHASE_TODO)

perf-local-clean: ## Delete volumes and scratch files
	$(PHASE_TODO)

# ---------------------------------------------------------------------------
# AWS mode (Phase 5 + 6)
# ---------------------------------------------------------------------------
perf-aws-init: ## tofu init
	$(PHASE_TODO)

perf-aws-deploy: ## tofu apply + deploy to 3 EC2
	$(PHASE_TODO)

perf-aws-run: ## Run the matrix on AWS
	$(PHASE_TODO)

perf-aws-report: ## Pull raw data and render the report
	$(PHASE_TODO)

perf-aws-down: ## Destroy the EC2 hosts
	$(PHASE_TODO)

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

parity-gateway: ## Bring up <PARITY_GATEWAY>, run <PARITY_PROFILE>, tear down
	@RUN_ID=$(PARITY_RUN_ID) bash scripts/parity-gateway.sh \
		--gateway $(PARITY_GATEWAY) \
		--profile $(PARITY_PROFILE) \
		--output  reports/$(PARITY_RUN_ID)/parity/$(PARITY_GATEWAY)-$(PARITY_PROFILE).json \
		--verbose

parity-gateway-all: ## Run every profile p01..p12 end-to-end against <PARITY_GATEWAY>
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

load-gateway: ## Single load cell end-to-end (k6 against one gateway × policy × scenario × load profile)
	@RUN_ID=$(LOAD_RUN_ID) bash scripts/load-gateway.sh \
		--gateway  $(LOAD_GATEWAY) \
		--policy   $(LOAD_POLICY) \
		--scenario $(LOAD_SCENARIO) \
		--load     $(LOAD_PROFILE) \
		--seed     $(LOAD_SEED) \
		$(LOAD_OPTS)

load-gateway-load-sweep: ## Sweep all 4 load profiles for one (LOAD_GATEWAY, LOAD_POLICY, LOAD_SCENARIO)
	@echo "$(YELLOW)load-gateway-load-sweep: $(LOAD_GATEWAY) / $(LOAD_POLICY) / $(LOAD_SCENARIO) × {p1-baseline,p2-sustained,p3-ramp,p4-stress}$(NC)"
	@passed=0; excluded=0; failed=0; \
	 for lp in p1-baseline p2-sustained p3-ramp p4-stress; do \
	     out_dir=reports/$(LOAD_RUN_ID)/raw/$(LOAD_GATEWAY)/$(LOAD_POLICY)__$${lp}__$(LOAD_SCENARIO); \
	     RUN_ID=$(LOAD_RUN_ID) bash scripts/load-gateway.sh \
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
	 echo ""; \
	 echo "$(CYAN)Summary:$(NC) $$passed PASS, $$failed FAIL, $$excluded EXCLUDED (reports in reports/$(LOAD_RUN_ID)/raw/$(LOAD_GATEWAY)/)"

# ---------------------------------------------------------------------------
# Orchestrator + aggregator (Phase 4 "Путь A" shell pipeline).
# ---------------------------------------------------------------------------
LOAD_POLICIES  ?=
LOAD_LOADS     ?= p1-baseline
LOAD_STOP_ON_FAIL ?= 0

load-sweep: ## Full matrix sweep: LOAD_GATEWAY × LOAD_POLICIES (default=all 12) × LOAD_LOADS (default=p1-baseline)
	@orch_args="--gateway $(LOAD_GATEWAY) --loads $(LOAD_LOADS) --seed $(LOAD_SEED)"; \
	 if [ -n "$(LOAD_POLICIES)" ]; then orch_args="$$orch_args --policies $(LOAD_POLICIES)"; fi; \
	 if [ "$(LOAD_STOP_ON_FAIL)" = "1" ]; then orch_args="$$orch_args --stop-on-fail"; fi; \
	 if [ -n "$(LOAD_RUN_ID)" ]; then orch_args="$$orch_args --run-id $(LOAD_RUN_ID)"; fi; \
	 bash scripts/load-orchestrator.sh $$orch_args

load-aggregate: ## Aggregate reports/$(LOAD_RUN_ID)/ into a wide CSV (format: csv|tsv|md)
	@bash scripts/aggregate-csv.sh --run-id $(LOAD_RUN_ID) --format $(or $(LOAD_FORMAT),csv)

load-combine: ## Combine N reports/<run-id>/ into one wide CSV (LOAD_RUN_IDS=id1,id2,…, format: csv|tsv|md)
	@bash scripts/aggregate-multi-csv.sh \
	    --run-ids $(LOAD_RUN_IDS) \
	    --format  $(or $(LOAD_FORMAT),csv) \
	    $(if $(LOAD_REGENERATE),--regenerate,) \
	    $(if $(LOAD_OUTPUT),--output $(LOAD_OUTPUT),)

load-report: ## Render a Chart.js HTML report from a combined CSV (LOAD_REPORT_INPUT=reports/<dir>/matrix.csv, LOAD_REPORT_OUTPUT=…/report.html)
	@python3 scripts/render-html-report.py \
	    --input  "$(LOAD_REPORT_INPUT)" \
	    --output "$(LOAD_REPORT_OUTPUT)" \
	    $(if $(LOAD_REPORT_TITLE),--title "$(LOAD_REPORT_TITLE)",) \
	    $(if $(LOAD_REPORT_ENV),--env "$(LOAD_REPORT_ENV)",)

