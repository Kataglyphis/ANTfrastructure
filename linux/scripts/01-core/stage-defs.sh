#!/usr/bin/env bash
# stage-defs.sh — declarative cross-chain stage graph.
#
# Single source of truth for the full cross lane pipeline:
#
#   base → compiler → sdk → media → android → runtime
#
# Each stage entry maps a stage name to its Dockerfile, tag function, parent
# stage, and whether it is per-architecture.  The orchestrator (build-cross-chain.sh)
# and --verify-chain both consume this graph so the chain is defined in exactly
# one place.  Single-stage rebuilds (build-cross-stage.sh) and standalone helpers
# (build-cross-compiler.sh) also consume the same functions.
#
# ── Stage Purposes ───────────────────────────────────────────────────────────
#
#   base     — Ubuntu-based foundation image: system packages, CMake, Node, uv.
#              Shared infrastructure, no arch-specific content.
#
#   compiler — Cross-compiler toolchains (GCC, LLVM/Clang, Rust, Python) for all
#              target architectures.  Single amd64 image; NOT a multi-arch manifest.
#
#   sdk      — Per-architecture SDK (Vulkan, TVM) built with the cross-compiler.
#              One image per target arch, all hosted on linux/amd64.
#
#   media    — Per-architecture media libraries (ONNX Runtime, LiteRT, OpenCV,
#              GStreamer, FFmpeg, libcamera) cross-compiled from the SDK base.
#
#   android  — Per-architecture Android SDK/NDK setup + native GCC swap (Canadian
#              cross for arm64/riscv64).  Produces the cross-lane's final artifacts.
#
#   runtime  — Delegates to build-runtime-manifest.sh.  Builds per-arch
#              base → package → torch/wrapper images on the real target platform
#              and publishes the multi-arch :latest-cross manifest.  NOT a cross
#              lane Dockerfile stage.
#
# ── STAGE HANDSHAKE PROTOCOL ─────────────────────────────────────────────────
#
# The cross lane is a sequence of separate `nerdctl build` invocations where
# each downstream stage does `FROM ${BASE_IMAGE}`.  To prevent stale-base reuse:
#
# 1. The orchestrator captures each pushed stage's registry-resolvable manifest
#    digest (via registry_pin_ref) and feeds it to the next stage as
#    `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`.
#
# 2. Content-addressed digests can never resolve to stale images, unlike mutable
#    tags which BuildKit may resolve from a stale local cache.
#
# 3. Per-arch stages (sdk, media, android) fan out one build per target
#    architecture.  Shared stages (base, compiler) build once.
#
# 4. The runtime stage delegates to build-runtime-manifest.sh (not a Dockerfile).
#
# To add or reorder stages:
#   1. Update CROSS_STAGE_ORDER and CROSS_PER_ARCH_STAGES arrays
#   2. Add entries in each switch-case function below
#   3. Declare the pin variable in the orchestrator (build-cross-chain.sh)
#   4. Update docs/linux-cross-builds.md and AGENTS.md
#
# Provides:
#   CROSS_STAGE_ORDER            ordered array of stage names
#   CROSS_PER_ARCH_STAGES         stages that fan out per architecture
#   cross_stage_dockerfile()     → Dockerfile path for a stage
#   cross_stage_parent()         → parent stage name (empty for base)
#   cross_stage_is_per_arch()    → true if stage fans out per architecture
#   cross_stage_tag()            → resolve tag for a stage (optionally per-arch)
#   cross_stage_build_args()     → extra --build-arg flags for a stage
#   cross_stage_pin_varname()    → variable name for the digest pin
#
# Dependency note: tag-naming.sh must already be sourced (stage-defs uses
# cross_*_tag() and runtime_*_tag() functions from tag-naming.sh).
[ -n "${_STAGE_DEFS_SH_LOADED:-}" ] && return 0
_STAGE_DEFS_SH_LOADED=1

# ── Stage order ───────────────────────────────────────────────────────────────
# The canonical ordered list of cross-lane stages.  Each stage depends on the
# previous one.  base and compiler are shared (one build each); sdk, media, and
# android are per-architecture; runtime delegates to build-runtime-manifest.sh.
# shellcheck disable=SC2034
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)

# Stages that fan out per target architecture (amd64, arm64, riscv64).
CROSS_PER_ARCH_STAGES=(sdk media android)

# ── Dockerfile mapping ────────────────────────────────────────────────────────
# Returns the Dockerfile path for a stage.  Runtime returns empty (delegates to
# build-runtime-manifest.sh, not a single Dockerfile).
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
# Returns the parent stage name.  base has no parent.  Every other stage depends
# on exactly one parent in the chain.
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
# Returns true (0) if the stage fans out per target architecture.
cross_stage_is_per_arch() {
  local stage="$1"
  for s in "${CROSS_PER_ARCH_STAGES[@]}"; do
    [ "${s}" = "${stage}" ] && return 0
  done
  return 1
}

# ── Tag resolution ────────────────────────────────────────────────────────────
# For per-arch stages (sdk, media, android) the second arg is required.
# For base and compiler it is ignored.  Delegates to tag-naming.sh functions.
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
      # base has no extra stage-specific args beyond the pinned parent
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
# Per-arch stages use associative arrays: SDK_PIN[arch], MEDIA_PIN[arch], etc.
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
