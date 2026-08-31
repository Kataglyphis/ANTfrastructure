#!/usr/bin/env bash
# stage-defs.sh — declarative cross-chain stage graph.
#
# Single source of truth for the cross lane:
#   base -> compiler -> sdk -> media -> android -> runtime
# Stage purposes, the digest handshake, and the provided functions are in
# docs/linux-cross-builds.md § Stage graph management functions (stage-defs.sh)
# and § Why the handoff must be pinned by digest.
#
# Adding or reordering a stage: update CROSS_STAGE_ORDER + CROSS_PER_ARCH_STAGES,
# add a case in each switch below, then update that doc and AGENTS.md. Pin
# variables are auto-declared by cross_stage_init_pins().
#
# Requires tag-naming.sh to be sourced first.
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

# ── Runtime lane ancestry graph (XC2) ──────────────────────────────────────────
# The cross-lane parent map (CROSS_STAGE_PARENT_MAP) ends at android→runtime.
# This table extends the machine-checked ancestry ONE lane further so the
# runtime walker (runtime_ancestry_assert_wrappers in ancestry.sh) can cover the
# android→package→wrapper edges. The package copies the cross-compiled payload
# out of the immutable android artifact; the wrapper layers the torch venv on the
# package. `android` is the cross lane's handoff — its tag/pin already exists.
# shellcheck disable=SC2034
declare -A RUNTIME_STAGE_PARENT_MAP=(
  [package]="android"
  [wrapper]="package"
)

# Parent stage of a runtime-lane stage (empty when unknown). android is the
# lane's root and is intentionally absent (it is a cross-lane stage).
runtime_stage_parent() {
  printf '%s' "${RUNTIME_STAGE_PARENT_MAP[$1]:-}"
}

# Per-arch tag for a runtime-lane stage. base/package/wrapper delegate to the
# runtime_*_tag helpers (tag-naming.sh); android resolves to the cross-lane
# artifact tag it was packaged from. Returns 1 for an unknown stage.
runtime_stage_tag() {
  local stage="$1" arch="${2:-}"
  case "${stage}" in
    base)    runtime_base_tag "${arch}" ;;
    package) runtime_package_tag "${arch}" ;;
    wrapper) runtime_wrapper_tag "${arch}" ;;
    android) cross_android_tag "${arch}" ;;
    *)       return 1 ;;
  esac
}

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
# Effective RAM divisor for per-arch parallel builds. When --parallel-archs is
# active, up to min(MAX_PARALLEL_ARCHS, #arches) per-arch builds compile
# CONCURRENTLY and share one host's RAM, so each must size its make/ninja job
# counts for RAM/N — parallelism.sh reads BUILD_MEM_DIVISOR to do exactly that.
# Historically this was documented as "injected by the orchestrator" but never
# actually set anywhere (only read), so --parallel-archs would N-times overcommit
# RAM and OOM. Serial builds (the default) → 1, i.e. unchanged behavior.
# $1 (optional): "shared" for single-build stages (base/compiler) — they run
# ALONE even under --parallel-archs, so they get divisor 1 (the empirically
# proven sequential sizing; intra-build step overlap is bounded by buildkitd
# max-parallelism, which has held since 2026-08-10). Default/per-arch: see PAR4.
cross_build_mem_divisor() {
  local kind="${1:-per-arch}"
  _bool_truthy "${PARALLEL_ARCHS:-0}" || { printf '1'; return 0; }
  # PAR4-AMEND (2026-08-19): the first wave4 launch applied the ×budget
  # divisor to the SHARED compiler stage too — throttled its LLVM build to
  # ~1/3 jobs at load 2 (projected +10h). Shared stages run alone: divisor 1.
  if [ "${kind}" = "shared" ]; then printf '1'; return 0; fi
  local n_arch max
  n_arch="$(arch_list_to_words "${TARGET_ARCHES:-}" | wc -w)"
  [ "${n_arch}" -ge 1 ] 2>/dev/null || n_arch=1
  max="${MAX_PARALLEL_ARCHS:-1}"
  [ "${max}" -ge 1 ] 2>/dev/null || max=1
  [ "${n_arch}" -lt "${max}" ] && max="${n_arch}"
  # PAR4 (2026-08-18): arch-count alone under-divides. buildkitd's
  # max-parallelism lets EACH build run several independent Dockerfile stages
  # concurrently, so N parallel arch builds can hold N × <intra> heavy compile
  # pools at once — with only ×N the pools were each sized for RAM/N and the
  # first post-PAR2 run OOM-killed cc1plus in two lanes' IREE builds (the PAR2
  # lock contention had been accidentally serializing those peaks). Budget 2
  # concurrent heavy steps per build (empirical: 2-4 observed, and ×5 total
  # held through the android×3 recovery run). Parallel-archs only — the
  # sequential path is empirically fine under max-parallelism alone.
  if [ "${max}" -gt 1 ]; then
    max=$(( max * ${PAR_INTRA_STEP_BUDGET:-2} ))
  fi
  printf '%s' "${max}"
}

append_cross_build_args() {
  local -n _acba_out=$1
  local _kind="${2:-per-arch}"
  _acba_out+=(--build-arg "BUILD_MODE=cross")
  _acba_out+=(--build-arg "BUILD_MEM_DIVISOR=$(cross_build_mem_divisor "${_kind}")")
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
      append_cross_build_args _csba_out shared
      _csba_out+=(--build-arg "CROSS_TARGETS=${CROSS_TARGETS}")
      # Forward host knobs the toolchain RUNs consume. Forwarded ONLY when set,
      # so the Dockerfile ARG defaults stay authoritative (same pattern as
      # ENABLE_NVIDIA on media). GCC_PARALLEL_TARGETS is the one that used to be
      # dropped here — the launch-time flag could never reach the container, so
      # the sequential GCC path won every time (backlog validation).
      append_optional_build_arg _csba_out GCC_PARALLEL_TARGETS "${GCC_PARALLEL_TARGETS:-}"
      append_optional_build_arg _csba_out GCC_HOST_BOOTSTRAP "${GCC_HOST_BOOTSTRAP:-}"
      append_optional_build_arg _csba_out GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE "${GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE:-}"
      ;;
    sdk)
      # VULKAN_VERSION needs no hand-forward here: append_version_build_args
      # (via append_common_build_args in _cross_stage_build_impl) auto-forwards
      # every non-noforward versions.env variable.
      append_cross_per_arch_build_args _csba_out "${arch}"
      ;;
    media)
      append_cross_per_arch_build_args _csba_out "${arch}"
      # Accelerator toggles: the runtime lane honors env ENABLE_NVIDIA/AMD
      # (append_runtime_accelerator_build_args), but the cross lane silently
      # dropped them — ENABLE_NVIDIA=true on build-cross-chain.sh built a
      # CPU-only media stage under a GPU-configured runtime, no warning.
      # Forward only when set, so the Dockerfile defaults stay authoritative.
      append_optional_build_arg _csba_out ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
      append_optional_build_arg _csba_out ENABLE_AMD "${ENABLE_AMD:-}"
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
