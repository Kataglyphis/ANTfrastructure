# `make help` lists targets over linux/scripts; env knobs: docs/linux-cross-builds.md § Operational env knobs (not versions.env)

ARCHES  ?= amd64,arm64,riscv64
STAGE   ?= base
REPO    ?= ghcr.io/kataglyphis/kataglyphis_beschleuniger
# Must equal build-cross-chain.sh's default, or make and a bare script call log to different places.
LOG_DIR ?= out/build-logs

SCRIPTS := linux/scripts

.DEFAULT_GOAL := help

.PHONY: help preflight lint lint-dockerfiles lint-workflows test-linux-scripts cross-build cross-stage verify-chain describe-chain smoke

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: ARCHES=$(ARCHES)  STAGE=$(STAGE)  LOG_DIR=$(LOG_DIR)"

hooks: ## Install the versioned git hooks (pre-commit fast gate, pre-push mutation coverage)
	git config core.hooksPath linux/host-config/git-hooks
	@echo "core.hooksPath -> linux/host-config/git-hooks (pre-commit runs the 8-27s gate; its mutation step is SAMPLED)"
	@echo "  pre-push adds what the sample skips: staleness over the whole mutation manifest, then --changed for real"

preflight: ## Fast no-build gate (shellcheck + verify-* suite)
	bash $(SCRIPTS)/preflight.sh

lint: ## shellcheck the whole tree at -S error
	bash $(SCRIPTS)/lint-shell.sh

lint-dockerfiles: ## hadolint all Dockerfiles (policy: .hadolint.yaml)
	bash $(SCRIPTS)/lint-dockerfiles.sh

lint-workflows: ## Lint GitHub workflows (actionlint)
	bash $(SCRIPTS)/lint-workflows.sh

test-linux-scripts: ## Unit tests for linux/scripts (tag naming, forwarding, disk guard)
	bash $(SCRIPTS)/tests/run-tests.sh

cross-build: ## Full base -> :latest for ARCHES
	bash $(SCRIPTS)/build-cross-chain.sh --target-arches $(ARCHES) --log-dir $(LOG_DIR)

cross-stage: ## Rebuild a single STAGE for ARCHES
	bash $(SCRIPTS)/build-cross-chain.sh --only $(STAGE) --target-arches $(ARCHES) --log-dir $(LOG_DIR)

verify-chain: ## Resolve upstream digests; exit 2 on stale downstream images
	bash $(SCRIPTS)/build-cross-chain.sh --verify-chain --target-arches $(ARCHES)

describe-chain: ## Print the full stage graph with tag names (no builds)
	bash $(SCRIPTS)/build-cross-chain.sh --describe-chain --target-arches $(ARCHES)

smoke: ## Host-side runtime-image boot smoke (IMAGE=<tag> ARCH=<arch>)
	@test -n "$(IMAGE)" || { echo "Usage: make smoke IMAGE=<tag> ARCH=<arch>"; exit 2; }
	bash $(SCRIPTS)/06-packaging/smoke-runtime-image.sh $(IMAGE) $(ARCH)
