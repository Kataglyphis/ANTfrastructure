#!/usr/bin/env bash
set -euo pipefail

# build-cross-stage.sh — build/push a single cross-lane stage via the stage graph.
# --push pins the parent digest; without it the image stays local.

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
EOF
  orchestrator_usage_mirror_options
  cat <<'EOF'
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

_stage_start_resource_monitor() {
  # RESOURCE_MONITOR=0 disables; self-terminates via --watch-pid.
  [ "${RESOURCE_MONITOR:-1}" = "1" ] || return 0
  local mon="${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh"
  [ -x "${mon}" ] || return 0
  local out="${LOG_DIR:-${REPO_ROOT}}"
  local rid="${CROSS_RUN_ID:-stage-${STAGE}${TARGET_ARCH:+-${TARGET_ARCH}}}"
  pgrep -f "resource-monitor.sh.*${rid}" >/dev/null 2>&1 && return 0
  bash "${mon}" --out-dir "${out}" --run-id "${rid}" --stage-log-dir "${out}" \
    --disk-path "${BUILDKIT_CACHE_DIR:-/}" --watch-pid "$$" </dev/null >/dev/null 2>&1 &
  log "resource-monitor: sampling -> ${out}/resources-${rid}.csv (RESOURCE_MONITOR=0 to disable)"
}

main() {
  # parallel-arch knobs parse for CLI-compat but do nothing here (single-arch)
  # — warn instead of silently ignoring them.
  ORCHESTRATOR_UNSUPPORTED_FLAGS="--parallel-archs --max-parallel-archs"
  run_orchestrator_arg_loop usage _cross_stage_extra_arg \
    TARGET_ARCH USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
    FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IMAGES \
    "$@"

  if [ -z "${STAGE}" ]; then
    err "--stage is required"
  fi

  cd "${REPO_ROOT}"

  _stage_start_resource_monitor

  cross_stage_init_pins

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

  cross_stage_run "${STAGE}" "${arch}" "${PUSH_IMAGES}"

  if [ "${PUSH_IMAGES}" -eq 1 ] && ! is_dry_run; then
    log "[stage ${label}] build complete (digest pinned)"
  fi
}

main "$@"
