#!/usr/bin/env bash
# stage-defs.sh — declarative cross-chain stage graph.
#
# Single source of truth for the full cross lane pipeline:
#
#   base -> compiler -> sdk -> media -> android -> runtime
#
# Each stage entry maps a stage name to its Dockerfile, tag function, parent
# stage, and whether it is per-architecture. The orchestrator and verify_chain
# both consume this graph so the chain is defined in exactly one place.
#
# Provides:
#   CROSS_STAGE_ORDER           ordered array of stage names
#   cross_stage_dockerfile()    → Dockerfile path for a stage
#   cross_stage_parent()        → parent stage name (empty for base)
#   cross_stage_is_per_arch()   → true if stage fans out per architecture
#   cross_stage_tag()           → resolve tag for a stage (optionally per-arch)
#   cross_stage_build_args()    → extra --build-arg flags for a stage
#   cross_stage_runtime_delegate() → hook for runtime stage delegation
#
# Dependency note: tag-naming.sh must already be sourced (stage-defs uses
# cross_*_tag() and runtime_*_tag() functions from tag-naming.sh).
[ -n "${_STAGE_DEFS_SH_LOADED:-}" ] && return 0
_STAGE_DEFS_SH_LOADED=1

# ── Stage order ───────────────────────────────────────────────────────────────
# The canonical ordered list of cross-lane stages. Each stage depends on the
# previous one.  base and compiler are shared (one build each); sdk, media, and
# android are per-architecture; runtime delegates to build-runtime-manifest.sh.
# shellcheck disable=SC2034  # consumed by build-cross-chain.sh after sourcing
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)

# Stages that fan out per target architecture (amd64, arm64, riscv64).
CROSS_PER_ARCH_STAGES=(sdk media android)

# ── Dockerfile mapping ────────────────────────────────────────────────────────
cross_stage_dockerfile() {
  case "${1}" in
    base)      printf '%s' "linux/Dockerfile.base" ;;
    compiler)  printf '%s' "linux/Dockerfile.toolchain" ;;
    sdk)       printf '%s' "linux/Dockerfile.sdk" ;;
    media)     printf '%s' "linux/Dockerfile.media" ;;
    android)   printf '%s' "linux/Dockerfile.android" ;;
    runtime)   printf '%s' "" ;;  # delegates to build-runtime-manifest.sh
    *)         return 1 ;;
  esac
}

# ── Parent stage (empty for base = no parent) ─────────────────────────────────
cross_stage_parent() {
  case "${1}" in
    compiler)  printf '%s' "base" ;;
    sdk)       printf '%s' "compiler" ;;
    media)     printf '%s' "sdk" ;;
    android)   printf '%s' "media" ;;
    runtime)   printf '%s' "android" ;;
    *)         printf '%s' "" ;;
  esac
}

# ── Per-arch check ────────────────────────────────────────────────────────────
cross_stage_is_per_arch() {
  local stage="$1"
  for s in "${CROSS_PER_ARCH_STAGES[@]}"; do
    [ "${s}" = "${stage}" ] && return 0
  done
  return 1
}

# ── Tag resolution ────────────────────────────────────────────────────────────
# For per-arch stages (sdk, media, android) the second arg is required.
# For base and compiler it is ignored.
cross_stage_tag() {
  local stage="$1" arch="${2:-}"
  case "${stage}" in
    base)      cross_base_tag ;;
    compiler)  cross_compiler_tag ;;
    sdk)       cross_sdk_tag "${arch}" ;;
    media)     cross_media_tag "${arch}" ;;
    android)   cross_android_tag "${arch}" ;;
    runtime)   printf '%s' "" ;;  # resolved in run_runtime_stage
    *)         return 1 ;;
  esac
}

# ── Extra build args per stage ────────────────────────────────────────────────
# Called by the orchestrator to append stage-specific --build-arg flags.
# Receives a nameref to the build-args array, the stage name, and the
# architecture (empty for base/compiler).
cross_stage_build_args() {
  local -n _csba_out=$1
  local stage="$2" arch="${3:-}"

  case "${stage}" in
    base)
      # no extra args beyond pinned base
      ;;
    compiler)
      _csba_out+=(
        --build-arg "BUILD_MODE=cross"
        --build-arg "CROSS_TARGETS=${CROSS_TARGETS}"
      )
      ;;
    sdk)
      _csba_out+=(
        --build-arg "BUILD_MODE=cross"
        --build-arg "TARGET_ARCH=${arch}"
        --build-arg "VULKAN_VERSION=${VULKAN_VERSION}"
      )
      ;;
    media)
      _csba_out+=(
        --build-arg "BUILD_MODE=cross"
        --build-arg "TARGET_ARCH=${arch}"
      )
      ;;
    android)
      _csba_out+=(
        --build-arg "BUILD_MODE=cross"
        --build-arg "TARGET_ARCH=${arch}"
      )
      ;;
    runtime)
      # runtime stage delegates to build-runtime-manifest.sh;
      # build args are assembled in run_runtime_stage() in the orchestrator.
      ;;
  esac
}

# ── Pin variable name for a stage ─────────────────────────────────────────────
# Returns the variable name used to store the digest pin for a stage.
# Per-arch stages use associative arrays: SDK_PIN, MEDIA_PIN, ANDROID_PIN.
cross_stage_pin_varname() {
  local stage="$1"
  case "${stage}" in
    base)      printf '%s' "BASE_PIN" ;;
    compiler)  printf '%s' "COMPILER_PIN" ;;
    sdk)       printf '%s' "SDK_PIN" ;;
    media)     printf '%s' "MEDIA_PIN" ;;
    android)   printf '%s' "ANDROID_PIN" ;;
    *)         printf '%s' "" ;;
  esac
}
