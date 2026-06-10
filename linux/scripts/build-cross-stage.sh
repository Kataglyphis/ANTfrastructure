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

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
TARGET_ARCH="${TARGET_ARCH:-}"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
init_mirror_defaults
LOG_DIR="${LOG_DIR:-}"

STAGE=""
PUSH_IMAGE=0
DRY_RUN=0

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

main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      TARGET_ARCH USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION PUSH_IMAGE \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --stage) STAGE="$2"; shift 2 ;;
      --arch) TARGET_ARCH="$2"; shift 2 ;;
      --cross-targets) CROSS_TARGETS="$2"; shift 2 ;;
      --log-dir) LOG_DIR="$2"; shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      *) err "Unknown option: $1" ;;
    esac
  done

  if [ -z "${STAGE}" ]; then
    err "--stage is required"
  fi

  cd "${REPO_ROOT}"

  # Validate stage exists and get metadata
  local dockerfile tag parent
  dockerfile="$(cross_stage_dockerfile "${STAGE}")" || {
    err "Unknown stage: ${STAGE}. Valid stages: ${CROSS_STAGE_ORDER[*]}"
  }
  [ -z "${dockerfile}" ] && err "Stage '${STAGE}' has no Dockerfile (delegates to another script)"

  local arch="${TARGET_ARCH}"
  local is_per_arch=0
  cross_stage_is_per_arch "${STAGE}" && is_per_arch=1

  if [ "${is_per_arch}" -eq 1 ] && [ -z "${arch}" ]; then
    err "Stage '${STAGE}' is per-architecture; --arch is required"
  fi

  tag="$(cross_stage_tag "${STAGE}" "${arch}")"
  [ -z "${tag}" ] && err "No tag for stage: ${STAGE} ${arch:+arch=${arch}}"

  local label="${STAGE}"
  [ "${is_per_arch}" -eq 1 ] && label="${STAGE}-${arch}"

  log "Building cross stage: ${label} -> ${tag}"

  # Assemble build args
  local -a build_args=()
  local parent_pin=""

  parent="$(cross_stage_parent "${STAGE}")"
  if [ -n "${parent}" ]; then
    local parent_tag
    parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
    [ -z "${parent_tag}" ] && err "No tag for parent stage: ${parent}"

    if [ "${PUSH_IMAGE}" -eq 1 ]; then
      # Pin the parent to its current registry digest so we consume a
      # content-addressed reference, not a mutable tag.
      parent_pin="$(retry 3 10 "registry digest for ${parent_tag}" registry_pin_ref "${NERDCTL_BIN}" "${parent_tag}")" || {
        err "Failed to resolve registry digest for parent ${parent_tag}"
      }
      [ -z "${parent_pin}" ] && err "Empty registry digest for parent ${parent_tag}"
      build_args+=(--build-arg "BASE_IMAGE=${parent_pin}")
      log "[stage ${label}] parent pinned to ${parent_pin}"
    else
      # Local build: use the mutable tag (may be stale, but we're not pushing
      # so no downstream stage can be affected).
      build_args+=(--build-arg "BASE_IMAGE=${parent_tag}")
      log "[stage ${label}] parent tag ${parent_tag} (local, not pinned)"
    fi
  fi

  cross_stage_build_args build_args "${STAGE}" "${arch}"

  # Build (local-only or push)
  if [ "${PUSH_IMAGE}" -eq 1 ]; then
    cross_stage_build_and_push "${label}" "${tag}" "${dockerfile}" "${build_args[@]}"
    local pinned
    pinned="$(retry 5 10 "registry digest for ${tag}" registry_pin_ref "${NERDCTL_BIN}" "${tag}")"
    log "[stage ${label}] pushed and pinned: ${pinned}"
  else
    cross_stage_build_local "${label}" "${tag}" "${dockerfile}" "${build_args[@]}"
    log "[stage ${label}] built locally: ${tag}"
  fi
}

main "$@"
