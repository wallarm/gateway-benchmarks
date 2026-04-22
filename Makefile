.DEFAULT_GOAL := help
.PHONY: help prereqs-check lint \
	backend-build backend-build-amd64 backend-run backend-smoke \
	orchestrator-build orchestrator-test \
	perf-local-up perf-local-run perf-local-report perf-local-down perf-local-clean \
	perf-aws-init perf-aws-deploy perf-aws-run perf-aws-report perf-aws-down \
	parity-check parity-check-all

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
	@echo "  $(GREEN)parity-check$(NC)          Run parity for a single profile (see PARITY_* vars)"
	@echo "  $(GREEN)parity-check-all$(NC)      Sweep parity across all 10 profiles against PARITY_TARGET"
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

parity-check-all: ## Run parity across every profile p01..p10 against PARITY_TARGET
	@echo "$(YELLOW)parity: sweeping p01..p10 against $(PARITY_TARGET)$(NC)"
	@mkdir -p $(PARITY_OUT)
	@set -e; \
	 passed=0; failed=0; \
	 for p in p01-vanilla p02-jwt p03-rl-static p04-rl-dynamic-low \
	          p05-rl-dynamic-high p06-req-headers p07-resp-headers \
	          p08-req-body p09-resp-body p10-full-pipeline; do \
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

