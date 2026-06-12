#!/usr/bin/env bash
set -euo pipefail

# build-cross-compiler.sh
#
# Standalone entry point to build the cross-compiler image.  Internally delegates
# to the shared stage-defs.sh graph (same pipeline as the orchestrator and
# build-cross-stage.sh) so the compiler stage is defined in exactly one place.
#
# When --push is used, the parent (base) is digest-pinned to avoid stale reuse.
# Without --push, the image stays local and the parent is resolved from either
# the local tag or the current registry tag.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
# CROSS_TARGETS is the compiler target arch list — distinct from TARGET_ARCHES
# which is used for which arches to build per-arch stages for.
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
init_mirror_defaults

REBUILD_BASE=0
PUSH_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-cross-compiler.sh [options]

Builds an amd64-hosted cross-compiler image containing cross toolchains for all
target architectures.  Internally delegates to the shared stage graph
(stage-defs.sh) — same pipeline as build-cross-chain.sh and build-cross-stage.sh.

The image stays local unless --push is requested.  If the remote base image is
unavailable, the script builds a local amd64 base image first and then uses it
for the compiler build.

Options:
  --cross-targets LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --image-repo REPO      Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --push                 Push the compiler image to the registry with digest pinning
  --rebuild-base         Always rebuild the local base image instead of trying pull first
  --dry-run              Print build commands without executing them
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during builds
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
  -h, --help             Show this help text

Examples:
  # Build locally (no push), fast mirror:
  bash linux/scripts/build-cross-compiler.sh \
    --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \
    --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/

  # Build and push:
  bash linux/scripts/build-cross-compiler.sh \
    --cross-targets amd64,arm64,riscv64 --push

  # Rebuild with a different image repo:
  bash linux/scripts/build-cross-compiler.sh \
    --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  USE_FAST_UBUNTU_MIRROR Set to true to replace Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL
EOF
}

# ── Compiler build ────────────────────────────────────────────────────────────
# Delegates to the shared cross_stage_run() from the stage graph.
# When pushing, the base parent is digest-pinned (no stale reuse).  When staying
# local, the base is built first via the stage graph (same logic as the
# orchestrator) instead of using a custom ensure_base_image() wrapper.
build_compiler() {
  cross_stage_run "compiler" "" "${PUSH_IMAGES}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  # Bind the shared parser's --target-arches arg to CROSS_TARGETS for this script
  while [ $# -gt 0 ]; do
    consume_shared_arg usage \
      parse_shared_orchestrator_args \
      CROSS_TARGETS USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO _cross_vulkan_version PUSH_IMAGES \
      "$1" "${2:-}" || break
    case "${_DP_SHIFT}" in
      1) shift; continue ;;  2) shift 2; continue ;;
    esac
    case "$1" in
      --cross-targets)
        CROSS_TARGETS="$2"
        shift 2
        ;;
      --rebuild-base)
        REBUILD_BASE=1
        shift
        ;;
      *)
        warn "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "${REPO_ROOT}"

  log "Cross-compiler build: targets=${CROSS_TARGETS} repo=${IMAGE_REPO} push=${PUSH_IMAGES}"

  if [ "${PUSH_IMAGES}" -eq 1 ]; then
    # Push path: build and push both base and compiler via the stage graph.
    # cross_stage_run handles digest-pinned parent resolution and pin capture,
    # so the compiler always consumes the freshly pushed base digest.
    cross_stage_run "base" "" 1
    cross_stage_run "compiler" "" 1
  else
    # Local path: build base locally first (shared stage graph, same as
    # orchestrator), then build compiler locally via the stage graph.
    cross_stage_run "base" "" 0
    cross_stage_run "compiler" "" 0
  fi
}

main "$@"
