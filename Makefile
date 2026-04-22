.DEFAULT_GOAL := help
.PHONY: help prereqs-check lint \
	backend-build backend-run \
	orchestrator-build orchestrator-test \
	perf-local-up perf-local-run perf-local-report perf-local-down perf-local-clean \
	perf-aws-init perf-aws-deploy perf-aws-run perf-aws-report perf-aws-down \
	parity-check

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
	@echo "  $(GREEN)backend-build$(NC)         Build the forked go-httpbin container"
	@echo "  $(GREEN)backend-run$(NC)           Run the backend locally on :8080"
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
	@echo "$(YELLOW)Quality:$(NC)"
	@echo "  $(GREEN)parity-check$(NC)          Run parity attestation only (no load)"
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
backend-build: ## Build the backend image
	$(PHASE_TODO)

backend-run: ## Run the backend locally
	$(PHASE_TODO)

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
parity-check: ## Run parity attestation only
	$(PHASE_TODO)
