# ==============================================================================
# Kataglyphis ContainerHub — cross-build entrypoint
#
# Thin, discoverable wrappers over linux/scripts/*. The scripts remain the
# source of truth; this file just gives a stable `make <target>` surface and
# documents the environment knobs that materially change build behavior.
#
#   make help            list targets
#   make preflight       fast, no-build gate (shellcheck + verify-* suite)
#   make cross-build     full base -> :latest-cross for ARCHES
#   make cross-stage     rebuild one STAGE for ARCHES
#   make verify-chain    resolve digests; exit 2 if any downstream image is STALE
#   make lint            shellcheck the tree at -S error
#
# Common variables (override on the command line, e.g. `make cross-build ARCHES=arm64`):
#   ARCHES   = amd64,arm64,riscv64   target architectures
#   STAGE    = base                  base|compiler|sdk|media|android|runtime
#   REPO     = ghcr.io/kataglyphis/kataglyphis_beschleuniger
#   LOG_DIR  = out/build-logs        per-stage build logs (same default as
#                                    build-cross-chain.sh — do NOT diverge:
#                                    two defaults meant `make cross-build` and
#                                    a bare script call wrote the same artifact
#                                    to two places, and each looked stale from
#                                    the other's directory)
#
# Environment knobs honored by the underlying scripts (export before make):
#   NO_CACHE=1              disable ALL build cache (force full rebuild)
#   NO_CACHE_EXPORT=1       keep local cache but skip the registry/inline export
#   BUILDKIT_CACHE_DIR=DIR  local buildkit cache root (default ~/.cache/kata-buildcache)
#   MAX_PARALLEL_ARCHS=N    concurrent per-arch stage builds (with --parallel-archs)
#   PARALLEL_ARCHS=1        build sdk/media/android arches in parallel
#   RUNTIME_IMAGE_SMOKE=0   skip the host-side runtime-image boot smoke
#   CROSS_LOG_ARCHIVE_KEEP=N  run dirs kept under LOG_DIR/archive (default 5;
#                             0 = keep all — the archive reached 12G unbounded)
#   BUILD_ATTEST=1          attach SLSA provenance + SBOM to pushed images (slower)
#
# Reproducibility pins (opt-in, see linux/scripts/01-core/versions.env):
#   OPENCV_COMMIT / OPENCV_CONTRIB_COMMIT / FFMPEG_COMMIT = 40-hex SHA to freeze
#   those branch-tracked sources to an immutable commit (empty = bleeding edge).
# ==============================================================================

ARCHES  ?= amd64,arm64,riscv64
STAGE   ?= base
REPO    ?= ghcr.io/kataglyphis/kataglyphis_beschleuniger
LOG_DIR ?= out/build-logs

SCRIPTS := linux/scripts

.DEFAULT_GOAL := help

.PHONY: help preflight lint lint-dockerfiles lint-workflows test-linux-scripts cross-build cross-stage verify-chain describe-chain smoke

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: ARCHES=$(ARCHES)  STAGE=$(STAGE)  LOG_DIR=$(LOG_DIR)"

hooks: ## Install the versioned git hooks (pre-commit fast gate)
	git config core.hooksPath linux/host-config/git-hooks
	@echo "core.hooksPath -> linux/host-config/git-hooks (pre-commit runs the 8-27s gate; its mutation step is SAMPLED)"

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

cross-build: ## Full base -> :latest-cross for ARCHES
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
