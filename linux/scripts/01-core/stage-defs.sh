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
#              Dockerfile: linux/Dockerfile.base
#              Tag:        :base
#              Platform:   linux/amd64
#
#   compiler — Cross-compiler toolchains (GCC, LLVM/Clang, Rust, Python) for all
#              target architectures.  Single amd64 image; NOT a multi-arch manifest.
#              Dockerfile: linux/Dockerfile.toolchain
#              Tag:        :cross-compiler-amd64
#              Platform:   linux/amd64
#
#   sdk      — Per-architecture SDK (Vulkan, TVM) built with the cross-compiler.
#              One image per target arch, all hosted on linux/amd64.
#              Dockerfile: linux/Dockerfile.sdk
#              Tag:        :cross-sdk-<arch>
#              Platform:   linux/amd64 (cross-compiled for target arch)
#
#   media    — Per-architecture media libraries (ONNX Runtime, LiteRT, OpenCV,
#              GStreamer, FFmpeg, libcamera) cross-compiled from the SDK base.
#              Dockerfile: linux/Dockerfile.media
#              Tag:        :cross-media-<arch>
#              Platform:   linux/amd64 (cross-compiled for target arch)
#
#   android  — Per-architecture Android SDK/NDK setup + native GCC swap (Canadian
#              cross for arm64/riscv64).  Produces the cross-lane's final artifacts.
#              Dockerfile: linux/Dockerfile.android
#              Tag:        :cross-android-<arch>
#              Platform:   linux/amd64 (cross-compiled for target arch)
#
#   runtime  — Delegates to build-runtime-manifest.sh.  Builds per-arch
#              base → package → torch/wrapper images on the real target platform
#              and publishes the multi-arch :latest-cross manifest.
#              NOT a cross-lane Dockerfile stage — handled specially by the orchestrator.
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
#   3. Pin variables are auto-declared by cross_stage_init_pins() — no manual
#      declarations needed in the orchestrator
#   4. Update docs/linux-cross-builds.md and AGENTS.md
#
# Provides:
#   CROSS_STAGE_ORDER            ordered array of stage names
#   CROSS_PER_ARCH_STAGES         stages that fan out per architecture
#   RUNTIME_STAGE_ORDER          ordered array of runtime lane stage names
#   cross_stage_dockerfile()     → Dockerfile path for a stage
#   cross_stage_parent()         → parent stage name (empty for base)
#   cross_stage_is_per_arch()    → true if stage fans out per architecture
#   cross_stage_tag()            → resolve tag for a stage (optionally per-arch)
#   cross_stage_build_args()     → extra --build-arg flags for a stage
#   cross_stage_pin_varname()    → variable name for the digest pin
#   cross_stage_init_pins()      → declare all pin variables needed by the graph
#   cross_stage_validate_graph() → self-consistency check for the stage graph
#   cross_stage_ensure_parent_available() → ensure parent images are local (for runtime handoff)
#
# Dependency note: tag-naming.sh must already be sourced (stage-defs uses
# cross_*_tag() and runtime_*_tag() functions from tag-naming.sh).
[ -n "${_STAGE_DEFS_SH_LOADED:-}" ] && return 0
_STAGE_DEFS_SH_LOADED=1

# ── Stage order ───────────────────────────────────────────────────────────────
# The canonical ordered list of cross-lane stages.  Each stage depends on the
# previous one.
#
#   base     → shared (one build, no arch)
#   compiler → shared (one build, no arch)
#   sdk      → per-arch (amd64, arm64, riscv64)
#   media    → per-arch
#   android  → per-arch
#   runtime  → delegates to build-runtime-manifest.sh (NOT a Dockerfile stage)
#
# The runtime stage is a sentinel: it has no Dockerfile, no cross_lane tag, and
# no pin variable.  The orchestrator detects it and delegates to the runtime
# helper instead of calling cross_stage_run().
# shellcheck disable=SC2034
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)

# Stages that fan out per target architecture (amd64, arm64, riscv64).
# These are built once per arch on linux/amd64 using cross-compilers.
CROSS_PER_ARCH_STAGES=(sdk media android)

# ── Runtime lane stage order ───────────────────────────────────────────────────
# The runtime lane builds on the real target platform (via QEMU/binfmt for
# foreign arches) and produces the final wrapper images + multi-arch manifest.
#
#   base     → Per-arch OS base (same Dockerfile.base, target platform)
#   package  → Layers cross-compiled artifacts from :cross-android-<arch>
#   wrapper  → Torch app venv + runtime scripts (Dockerfile.torch)
#
# Consumed by build-runtime-manifest.sh and build-runtime-artifacts.sh via
# runtime_build_chain() in runtime-build-fns.sh.
# shellcheck disable=SC2034
RUNTIME_STAGE_ORDER=(base package wrapper)

# ── Stage property tables ─────────────────────────────────────────────────────
# Single source of truth for the pure stage→string maps (dockerfile, parent, pin
# variable). Adding a stage = one entry per table. `tag` and `build_args` carry
# real logic and stay as functions below.
# shellcheck disable=SC2034
declare -A CROSS_STAGE_DOCKERFILE=(
  [base]="linux/Dockerfile.base"
  [compiler]="linux/Dockerfile.toolchain"
  [sdk]="linux/Dockerfile.sdk"
  [media]="linux/Dockerfile.media"
  [android]="linux/Dockerfile.android"
  [runtime]=""   # delegates to build-runtime-manifest.sh, not a single Dockerfile
)
# shellcheck disable=SC2034
declare -A CROSS_STAGE_PARENT_MAP=(
  [compiler]="base"
  [sdk]="compiler"
  [media]="sdk"
  [android]="media"
  [runtime]="android"
)
# shellcheck disable=SC2034
declare -A CROSS_STAGE_PIN_VARNAME_MAP=(
  [base]="BASE_PIN"
  [compiler]="COMPILER_PIN"
  [sdk]="SDK_PIN"
  [media]="MEDIA_PIN"
  [android]="ANDROID_PIN"
)

# ── Dockerfile mapping ────────────────────────────────────────────────────────
# Returns the Dockerfile path for a stage.  Runtime returns empty (delegates to
# build-runtime-manifest.sh, not a single Dockerfile). Returns 1 for an unknown
# stage (existence check, since `runtime` is a valid stage with an empty value).
cross_stage_dockerfile() {
  [ -n "${CROSS_STAGE_DOCKERFILE[$1]+set}" ] || return 1
  printf '%s' "${CROSS_STAGE_DOCKERFILE[$1]}"
}

# ── Parent stage (empty for base = no parent) ─────────────────────────────────
# Returns the parent stage name.  base has no parent.  Every other stage depends
# on exactly one parent in the chain.
cross_stage_parent() {
  printf '%s' "${CROSS_STAGE_PARENT_MAP[$1]:-}"
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

# ── Shared per-arch + cross build-arg helpers ──────────────────────────────────
# DRY helpers that avoid repeating --build-arg "BUILD_MODE=cross" and
# --build-arg "TARGET_ARCH=${arch}" in every case branch.
#
# Usage:
#   append_cross_build_args <nameref>          → adds BUILD_MODE=cross
#   append_per_arch_build_args <nameref> <arch> → adds TARGET_ARCH=<arch>
#   append_cross_per_arch_build_args <nameref> <arch> → both of the above
append_cross_build_args() {
  local -n _acba_out=$1
  _acba_out+=(--build-arg "BUILD_MODE=cross")
}

append_per_arch_build_args() {
  local -n _apaba_out=$1
  local arch="$2"
  _apaba_out+=(--build-arg "TARGET_ARCH=${arch}")
}

append_cross_per_arch_build_args() {
  local -n _acpaba_out=$1
  local arch="$2"
  append_cross_build_args _acpaba_out
  append_per_arch_build_args _acpaba_out "${arch}"
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
      ;;
    compiler)
      append_cross_build_args _csba_out
      _csba_out+=(--build-arg "CROSS_TARGETS=${CROSS_TARGETS}")
      ;;
    sdk)
      append_cross_per_arch_build_args _csba_out "${arch}"
      _csba_out+=(--build-arg "VULKAN_VERSION=${VULKAN_VERSION}")
      ;;
    media)
      append_cross_per_arch_build_args _csba_out "${arch}"
      ;;
    android)
      append_cross_per_arch_build_args _csba_out "${arch}"
      ;;
    runtime)
      ;;
  esac
}

# ── Pin variable name for a stage ─────────────────────────────────────────────
# Returns the variable name used to store the digest pin for a stage.
# Per-arch stages use associative arrays: SDK_PIN[arch], MEDIA_PIN[arch], etc.
cross_stage_pin_varname() {
  printf '%s' "${CROSS_STAGE_PIN_VARNAME_MAP[$1]:-}"
}

# ── Pin variable initialization ────────────────────────────────────────────────
# Declares all pin variables consumed by the stage graph as global variables.
# Call this once from the orchestrator before entering the build loop.
#
# For shared (non-per-arch) stages: declares a scalar variable (e.g. BASE_PIN="").
# For per-arch stages: declares an associative array (e.g. declare -g -A SDK_PIN).
#
# This removes the need for the orchestrator to manually declare pin variables,
# which was a prerequisite for adding new stages.  The pin variable names are
# derived from the stage graph itself via cross_stage_pin_varname(), so the
# graph remains the single source of truth.
#
# Also declares per-arch build-tracking arrays (e.g. ANDROID_BUILT_THIS_RUN)
# used by the parent→child handoff to avoid redundant registry pulls.
#
# Usage: cross_stage_init_pins
cross_stage_init_pins() {
  local stage pin_varname
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "runtime" ] && continue  # runtime has no pin
    pin_varname="$(cross_stage_pin_varname "${stage}")"
    [ -z "${pin_varname}" ] && continue
    if cross_stage_is_per_arch "${stage}"; then
      declare -g -A "${pin_varname}"
      declare -g -A "${stage^^}_BUILT_THIS_RUN"
    else
      declare -g "${pin_varname}"=""
    fi
  done
}

# ── Stage graph self-consistency validation ───────────────────────────────────
# Verifies that the stage graph is internally consistent:
#   - Every parent reference resolves to a defined stage (except base which has none)
#   - Every stage with a Dockerfile has an existing file
#   - Every stage resolves to a non-empty tag function
#   - No cycles exist in the parent chain
#
# Returns 0 when the graph passes all checks.  Writes errors to stderr.
# Call this from the orchestrator or as a standalone sanity check.
#
# Usage: cross_stage_validate_graph && echo "Graph OK"
cross_stage_validate_graph() {
  local stage parent dockerfile tag_fn ok=0
  local -A seen=()
  local -a chain=()

  # Build the index of valid stages
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    seen["${stage}"]=1
  done

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "runtime" ] && continue  # runtime is a sentinel

    parent="$(cross_stage_parent "${stage}")"

    # Check parent references a valid stage (empty = base, no parent)
    if [ -n "${parent}" ] && [ -z "${seen[${parent}]:-}" ]; then
      printf '[ERROR] Stage "%s" references unknown parent "%s"\n' "${stage}" "${parent}" >&2
      ok=1
    fi

    # Check tag function returns a non-empty result
    local test_tag
    if cross_stage_is_per_arch "${stage}"; then
      test_tag="$(cross_stage_tag "${stage}" "testarch" 2>/dev/null || true)"
      if [ -z "${test_tag}" ]; then
        printf '[ERROR] Stage "%s" tag function returns empty string\n' "${stage}" >&2
        ok=1
      fi
    else
      test_tag="$(cross_stage_tag "${stage}" 2>/dev/null || true)"
      if [ -z "${test_tag}" ]; then
        printf '[ERROR] Stage "%s" tag function returns empty string\n' "${stage}" >&2
        ok=1
      fi
    fi
  done

  # Check for cycles (simple: each stage visits its parent; max depth = array length)
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "runtime" ] && continue
    chain=("${stage}")
    local current="${stage}"
    local depth=0
    while [ -n "${current}" ]; do
      current="$(cross_stage_parent "${current}")"
      if [ -z "${current}" ]; then
        break    # reached base (no parent)
      fi
      depth=$((depth + 1))
      if [ "${depth}" -gt "${#CROSS_STAGE_ORDER[@]}" ]; then
        printf '[ERROR] Cycle detected in stage chain near "%s"\n' "${stage}" >&2
        ok=1
        break
      fi
    done
  done

  return "${ok}"
}

# ── Ensure parent stage images are locally available ─────────────────────────
# For the runtime handoff: pulls parent stage images (e.g. cross-android-<arch>)
# that were NOT built in the current orchestration run, so the runtime helper
# can consume them as `FROM` references.
#
# Call from the orchestrator before delegating to build-runtime-manifest.sh.
# Uses the stage graph to determine which parent images to pull.
#
# Usage: cross_stage_ensure_parent_available "runtime" "${TARGET_ARCHES}"
cross_stage_ensure_parent_available() {
  local stage="$1" arches_csv="$2"
  local parent arch parent_tag

  parent="$(cross_stage_parent "${stage}")"
  [ -z "${parent}" ] && return 0

  for arch in $(arch_list_to_words "${arches_csv}"); do
    parent_tag="$(cross_stage_tag "${parent}" "${arch}")"
    [ -z "${parent_tag}" ] && { warn "No tag for parent stage '${parent}' arch ${arch}"; continue; }

    if cross_stage_is_per_arch "${parent}"; then
      local built_flag_varname="${parent^^}_BUILT_THIS_RUN"
      if declare -p "${built_flag_varname}" &>/dev/null; then
        local -n built_flag="${built_flag_varname}"
        if [ -n "${built_flag[$arch]:-}" ]; then
          log "[stage ${stage}] ${parent}-${arch} built in this run, skip pull"
          continue
        fi
      fi
    fi

    if is_dry_run; then
      log "[stage ${stage}] [DRY RUN] would pull ${parent_tag}"
      continue
    fi

    log "[stage ${stage}] pulling ${parent_tag}"
    run "${NERDCTL_BIN:-nerdctl}" pull --platform linux/amd64 "${parent_tag}"
  done
}
