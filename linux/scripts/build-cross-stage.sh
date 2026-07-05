#!/usr/bin/env bash
set -euo pipefail

# build-cross-stage.sh
#
# Build and optionally push a single cross-lane stage by name, using the
# declarative stage graph in stage-defs.sh to resolve the Dockerfile, parent
# tag, and build args.
#
# When --push is used, the parent's registry digest is pinned so the stage
# consumes a content-addressed FROM reference instead of a mutable tag.
# Without --push, the image stays local and cross_stage_build_local() (from
# cross-stage-build.sh) handles the build.
#
# Usage:
#   bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64
#   bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push
#   bash linux/scripts/build-cross-stage.sh --stage compiler

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

TARGET_ARCH="${TARGET_ARCH:-}"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
LOG_DIR="${LOG_DIR:-}"

STAGE=""
PUSH_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-cross-stage.sh --stage STAGE [--arch ARCH] [options]

Build a single cross-lane stage by name using the declarative stage graph.

Stages: base, compiler, sdk, media, android
(Per-arch stages sdk/media/android require --arch.)

Options:
  --stage STAGE        Stage name to build (required)
  --arch ARCH          Target architecture for per-arch stages
  --push               Push the built image to the registry with digest pinning
  --log-dir DIR        Tee build output into DIR/<stage>[-<arch>].log
  --dry-run            Print the build command without executing
  --fast-ubuntu-mirror Replace Ubuntu archive/security/ports mirrors
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
  --image-repo REPO    Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --cross-targets LIST Compiler target list (for compiler stage, default: amd64,arm64,riscv64)
  --vulkan-version VER Vulkan SDK version (for sdk stage)
  -h, --help           Show this help text

Examples:
  # Build sdk for arm64 locally (no push):
  bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64

  # Build and push media for amd64 with digest pinning:
  bash linux/scripts/build-cross-stage.sh --stage media --arch amd64 --push

  # Build compiler (shared, no --arch needed):
  bash linux/scripts/build-cross-stage.sh --stage compiler --push

  # Build base (no parent stage):
  bash linux/scripts/build-cross-stage.sh --stage base --push
EOF
}

_cross_stage_extra_arg() {
  case "$1" in
    --stage) STAGE="$2"; _OARG_SHIFT=2 ;;
    --arch) TARGET_ARCH="$2"; _OARG_SHIFT=2 ;;
    --cross-targets) CROSS_TARGETS="$2"; _OARG_SHIFT=2 ;;
    --log-dir) LOG_DIR="$2"; _OARG_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

main() {
  run_orchestrator_arg_loop usage _cross_stage_extra_arg \
    TARGET_ARCH USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
    FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IMAGES \
    "$@"

  if [ -z "${STAGE}" ]; then
    err "--stage is required"
  fi

  cd "${REPO_ROOT}"

  # Init pin arrays so cross_stage_run can access parent pin variables
  cross_stage_init_pins

  # Validate stage exists
  local dockerfile arch is_per_arch
  dockerfile="$(cross_stage_dockerfile "${STAGE}")" || {
    err "Unknown stage: ${STAGE}. Valid stages: ${CROSS_STAGE_ORDER[*]}"
  }
  [ -z "${dockerfile}" ] && err "Stage '${STAGE}' has no Dockerfile (delegates to another script)"

  arch="${TARGET_ARCH}"
  is_per_arch=0
  cross_stage_is_per_arch "${STAGE}" && is_per_arch=1

  if [ "${is_per_arch}" -eq 1 ] && [ -z "${arch}" ]; then
    err "Stage '${STAGE}' is per-architecture; --arch is required"
  fi

  local label="${STAGE}"
  [ "${is_per_arch}" -eq 1 ] && label="${STAGE}-${arch}"

  # Delegate the full build (parent resolution, build args, push/local, pin capture)
  # to the shared cross_stage_run() from cross-stage-build.sh.
  cross_stage_run "${STAGE}" "${arch}" "${PUSH_IMAGES}"

  if [ "${PUSH_IMAGES}" -eq 1 ] && ! is_dry_run; then
    log "[stage ${label}] build complete (digest pinned)"
  fi
}

main "$@"
