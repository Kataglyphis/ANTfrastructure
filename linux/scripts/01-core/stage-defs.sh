#!/usr/bin/env bash
# Cross-chain stage graph; source tag-naming.sh first. docs/linux-cross-builds.md#stage-graph-management-functions-stage-defssh
[ -n "${_STAGE_DEFS_SH_LOADED:-}" ] && return 0
_STAGE_DEFS_SH_LOADED=1

# Stage order; runtime is a sentinel (no Dockerfile, tag or pin) delegated to build-runtime-manifest.sh.
# shellcheck disable=SC2034
CROSS_STAGE_ORDER=(base compiler sdk media android runtime)

# Built once per target arch on CROSS_BUILD_PLATFORM with cross-compilers.
CROSS_PER_ARCH_STAGES=(sdk media android)

# A GPU variant inserts a gpu stage after sdk; decided at source time, so it is an environment knob only.
CROSS_GPU_VARIANT="$(cross_variant)" || return 1
if [ -n "${CROSS_GPU_VARIANT}" ]; then
  CROSS_STAGE_ORDER=(base compiler sdk gpu media android runtime)
  CROSS_PER_ARCH_STAGES=(sdk gpu media android)
fi
# Set ENABLE_* here for every entry point, so no -<variant> tag gets CPU args; TensorRT is off (no libnvinfer shipped).
case "${CROSS_GPU_VARIANT}" in
  nvidia) ENABLE_NVIDIA=true; ENABLE_AMD=false; : "${ENABLE_TENSORRT:=false}"
          export CROSS_VARIANT=nvidia ENABLE_NVIDIA ENABLE_AMD ENABLE_TENSORRT ;;
  rocm)   ENABLE_AMD=true; ENABLE_NVIDIA=false
          export CROSS_VARIANT=rocm ENABLE_NVIDIA ENABLE_AMD ;;
esac

# <first_stage> <arches>: prints why a variant run must not start. docs/linux-accelerator-images.md#nvidia-gpu-build-linux
cross_variant_refusal() {
  [ -n "${CROSS_GPU_VARIANT}" ] || return 0
  local v="${CROSS_GPU_VARIANT}" first="$1" arches="$2" a plat plat_arch
  case "${first}" in
    base|compiler|sdk)
      printf 'the %s variant cannot build %s: base, compiler and sdk are shared with the default chain. Rebuild them there, then start this one at gpu.' "${v}" "${first}"
      return 0 ;;
  esac
  plat="$(cross_build_platform)"; plat_arch="${plat#linux/}"
  if [ "${plat_arch}" != "amd64" ] && [ "${CROSS_NO_PUSH:-0}" != "1" ]; then
    printf 'the %s variant can only PUSH from an amd64 build platform (CROSS_BUILD_PLATFORM is %s): the shared sdk it builds on is the amd64 lane'"'"'s. On an arm64 host build it --no-push (the Jetson lane, docs/linux-accelerator-images.md).' "${v}" "${plat}"
    return 0
  fi
  for a in $(arch_list_to_words "${arches}"); do
    if [ "${v}" = "rocm" ] && [ "${a}" != "amd64" ]; then
      printf 'the rocm variant is amd64-only (ROCm ships no %s userspace); got %s' "${a}" "${arches}"
      return 0
    fi
    if [ "${a}" != "${plat_arch}" ]; then
      printf 'the %s variant cannot cross-build %s on the %s build platform: the GPU stack is installed for, and compiled against, the build platform. Build %s natively.' "${v}" "${a}" "${plat}" "${a}"
      return 0
    fi
  done
}

# Runtime lane stages, declarative only: runtime_build_chain calls its steps directly.
# shellcheck disable=SC2034
RUNTIME_STAGE_ORDER=(base package wrapper)

# Extends the checked ancestry past android, so runtime_ancestry_assert_wrappers covers package and wrapper.
# shellcheck disable=SC2034
declare -A RUNTIME_STAGE_PARENT_MAP=(
  [package]="android"
  [wrapper]="package"
)

# Empty for android, the lane's root (a cross-lane stage).
runtime_stage_parent() {
  printf '%s' "${RUNTIME_STAGE_PARENT_MAP[$1]:-}"
}

# Per-arch tag of a runtime-lane stage; android resolves to the cross-lane artifact tag.
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

# Stage property tables: adding a stage is one entry per table; tag and build args stay functions.
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
# The variant's gpu stage: its Dockerfile, its edges, its pin.
case "${CROSS_GPU_VARIANT}" in
  nvidia) CROSS_STAGE_DOCKERFILE[gpu]="linux/Dockerfile.nvidia" ;;
  rocm)   CROSS_STAGE_DOCKERFILE[gpu]="linux/Dockerfile.amd" ;;
esac
if [ -n "${CROSS_GPU_VARIANT}" ]; then
  CROSS_STAGE_PARENT_MAP[gpu]="sdk"
  CROSS_STAGE_PARENT_MAP[media]="gpu"
  CROSS_STAGE_PIN_VARNAME_MAP[gpu]="GPU_PIN"
fi

# Empty for runtime; returns 1 only for an unknown stage.
cross_stage_dockerfile() {
  [ -n "${CROSS_STAGE_DOCKERFILE[$1]+set}" ] || return 1
  printf '%s' "${CROSS_STAGE_DOCKERFILE[$1]}"
}

# Parent stage; empty for base.
cross_stage_parent() {
  printf '%s' "${CROSS_STAGE_PARENT_MAP[$1]:-}"
}

cross_stage_is_per_arch() {
  # s must be local: the disk guard calls this inside its own `for s` loop.
  local stage="$1" s
  for s in "${CROSS_PER_ARCH_STAGES[@]}"; do
    [ "${s}" = "${stage}" ] && return 0
  done
  return 1
}

# Per-arch stages need the arch argument; shared ones ignore it.
cross_stage_tag() {
  local stage="$1" arch="${2:-}"
  case "${stage}" in
    base)      cross_base_tag ;;
    compiler)  cross_compiler_tag ;;
    sdk)       cross_sdk_tag "${arch}" ;;
    gpu)       [ -n "${CROSS_GPU_VARIANT}" ] || return 1; cross_gpu_tag "${arch}" ;;
    media)     cross_media_tag "${arch}" ;;
    android)   cross_android_tag "${arch}" ;;
    runtime)   printf '%s' "" ;;  # resolved in run_runtime_stage
    *)         return 1 ;;
  esac
}

# BUILD_MEM_DIVISOR: concurrent --parallel-archs builds share one host's RAM. docs/build-parallelism-memory-tuning.md
cross_build_mem_divisor() {
  local kind="${1:-per-arch}"
  _bool_truthy "${PARALLEL_ARCHS:-0}" || { printf '1'; return 0; }
  # Shared stages run alone even under --parallel-archs, so they keep divisor 1.
  if [ "${kind}" = "shared" ]; then printf '1'; return 0; fi
  local n_arch max
  n_arch="$(arch_list_to_words "${TARGET_ARCHES:-}" | wc -w)"
  [ "${n_arch}" -ge 1 ] 2>/dev/null || n_arch=1
  max="${MAX_PARALLEL_ARCHS:-1}"
  [ "${max}" -ge 1 ] 2>/dev/null || max=1
  [ "${n_arch}" -lt "${max}" ] && max="${n_arch}"
  # Each build also runs several heavy stages at once under buildkitd max-parallelism, so budget for that too.
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

# Stage-specific build args: <nameref> <stage> [arch]
cross_stage_build_args() {
  local -n _csba_out=$1
  local stage="$2" arch="${3:-}"

  case "${stage}" in
    base)
      ;;
    compiler)
      append_cross_build_args _csba_out shared
      _csba_out+=(--build-arg "CROSS_TARGETS=${CROSS_TARGETS}")
      # Host knobs reach the container only as build args; forwarded only when set, so ARG defaults stay authoritative.
      append_optional_build_arg _csba_out GCC_PARALLEL_TARGETS "${GCC_PARALLEL_TARGETS:-}"
      append_optional_build_arg _csba_out GCC_HOST_BOOTSTRAP "${GCC_HOST_BOOTSTRAP:-}"
      append_optional_build_arg _csba_out GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE "${GCC_CANADIAN_CROSS_SKIP_ON_LINK_FAILURE:-}"
      ;;
    sdk)
      # VULKAN_VERSION is auto-forwarded with every non-noforward versions.env variable.
      append_cross_per_arch_build_args _csba_out "${arch}"
      ;;
    gpu)
      append_cross_per_arch_build_args _csba_out "${arch}"
      # Dockerfile.nvidia's knobs (Dockerfile.amd has none beyond the pins).
      append_optional_build_arg _csba_out ENABLE_TENSORRT "${ENABLE_TENSORRT:-}"
      append_optional_build_arg _csba_out CUDA_INSTALL_COMPAT "${CUDA_INSTALL_COMPAT:-}"
      # rocm: the ASAN tree beside the normal one, off by default for its size.
      append_optional_build_arg _csba_out ENABLE_ROCM_ASAN "${ENABLE_ROCM_ASAN:-}"
      ;;
    media)
      append_cross_per_arch_build_args _csba_out "${arch}"
      # Forward accelerator toggles (only when set), or a GPU run builds a CPU-only media stage.
      append_optional_build_arg _csba_out ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
      append_optional_build_arg _csba_out ENABLE_AMD "${ENABLE_AMD:-}"
      # ENABLE_TENSORRT=false keeps the CUDA EP without TensorRT (Jetson); TVM_USE_CUDA would otherwise inherit 0.
      append_optional_build_arg _csba_out ENABLE_TENSORRT "${ENABLE_TENSORRT:-}"
      append_optional_build_arg _csba_out TVM_USE_CUDA "${TVM_USE_CUDA:-}"
      # CUDA_MB_PER_CICC sizes the CUDA job count; merely exported, it never reaches the container.
      append_optional_build_arg _csba_out CUDA_MB_PER_CICC "${CUDA_MB_PER_CICC:-}"
      ;;
    android)
      append_cross_per_arch_build_args _csba_out "${arch}"
      ;;
    runtime)
      ;;
  esac
}

# Digest pin variable of a stage; per-arch stages use associative arrays (SDK_PIN[arch]).
cross_stage_pin_varname() {
  printf '%s' "${CROSS_STAGE_PIN_VARNAME_MAP[$1]:-}"
}

# Declares every pin and *_BUILT_THIS_RUN variable from the graph; call once before the build loop.
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

# Graph self-check: known parents, non-empty tags, no cycles; errors go to stderr.
cross_stage_validate_graph() {
  local stage parent ok=0
  local -A seen=()

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    seen["${stage}"]=1
  done

  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "runtime" ] && continue  # runtime is a sentinel

    parent="$(cross_stage_parent "${stage}")"

    if [ -n "${parent}" ] && [ -z "${seen[${parent}]:-}" ]; then
      printf '[ERROR] Stage "%s" references unknown parent "%s"\n' "${stage}" "${parent}" >&2
      ok=1
    fi

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

  # Cycle check: a parent walk longer than the stage list must loop.
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    [ "${stage}" = "runtime" ] && continue
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

# Pulls parent images not built in this run, so the runtime helper can use them as FROM references.
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
    run "${NERDCTL_BIN:-nerdctl}" pull --platform "$(cross_build_platform)" "${parent_tag}"
  done
}
