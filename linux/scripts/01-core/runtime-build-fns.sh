# shellcheck shell=bash
# runtime-build-fns.sh
# Per-architecture image build functions for the runtime packaging chain.
# Sourced by artifact-common.sh — do not source this directly.
#
# Provides:
#   runtime_build_base_image
#   runtime_build_package_image
#   runtime_build_wrapper_image
#   runtime_build_wrapper_rootfs
#   runtime_build_chain
#   runtime_write_artifact_metadata
#
# Depends on functions defined in artifact-common.sh:
#   append_common_build_args, run_nerdctl_build, run, image_exists,
#   export_image_to_oci_layout, export_image_rootfs_dir,
#   remove_local_image_if_exists, runtime_*_tag(), runtime_artifact_*,
#   runtime_stage_context_*, runtime_use_local_*, etc.

# Post-build: export to OCI layout locally, or push remotely, then clean up.
# Push a built runtime image tag, retrying on transient registry/network
# failures. A ~8GiB wrapper push over a throttled link can reset mid-transfer
# ("use of closed network connection: Put .../blobs/upload/..."); without a
# retry that discards the whole runtime stage -- and pre-fix, exited the entire
# chain run after hours of work. Bounded by PUSH_MAX_ATTEMPTS (default 4) with
# PUSH_RETRY_BASE_SECS (default 15s) between attempts. Pure network op, so any
# failure is retried up to the cap (a genuine auth/config error just exhausts it
# in <1min); the image layers are already built, only the upload repeats.
runtime_push_tag() {
  local tag="$1"
  retry "${PUSH_MAX_ATTEMPTS:-4}" "${PUSH_RETRY_BASE_SECS:-15}" "push ${tag}" \
    run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
}

_runtime_finish_stage() {
  local kind="$1"
  local arch="$2"
  local tag="$3"
  local parent_kind="${4:-}"

  if runtime_use_local_stage_context_outputs; then
    local context_dir
    context_dir="$(runtime_stage_context_dir "${kind}" "${arch}")"
    export_image_to_oci_layout "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}"
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
  else
    if runtime_pushes_intermediate_images; then
      runtime_push_tag "${tag}"
    fi
    if [ "${kind}" != "wrapper" ] || ! runtime_pushes_wrapper_images; then
      runtime_refresh_stage_context "${kind}" "${arch}" "${tag}"
    fi
  fi

  if [ -n "${parent_kind}" ]; then
    runtime_remove_stage_context "${parent_kind}" "${arch}"
  fi
}

runtime_build_base_image() {
  local arch="$1"
  local tag context_dir
  local -a build_args=()

  tag="$(runtime_base_tag "${arch}")"
  append_common_build_args build_args
  append_runtime_base_parent_build_arg build_args

  if is_dry_run; then
    log "[DRY RUN] would build base image ${tag} (platform linux/${arch})"
    return 0
  fi

  # rc propagation: this runs under a disabled-errexit extent (see
  # runtime_build_chain) — failures must be RETURNED, not assumed fatal.
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=true \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${BASE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    . || return 1

  if runtime_use_local_stage_context_outputs; then
    context_dir="$(runtime_stage_context_dir base "${arch}")"
    _export_container_rootfs "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}" || return 1
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
    return 0
  fi

  if runtime_pushes_intermediate_images; then
    runtime_push_tag "${tag}"
  fi

  runtime_refresh_stage_context base "${arch}" "${tag}"
}

# ── Per-stage build-arg assembly helpers ──────────────────────────────────────
# DRY the inline --build-arg strings that are repeated across runtime_build_package_image
# and _runtime_build_wrapper.  Use append_common_build_args first, then call these.
#
# Usage:
#   append_package_build_args <nameref> <arch> <parent_image> <artifact_image> <package_base_stage>
#   append_wrapper_build_args <nameref> <arch> <parent_image>
append_package_build_args() {
  local -n _apba_out=$1
  local arch="$2" parent_image="$3" artifact_image="$4" package_base_stage="$5"
  _apba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "ARTIFACT_IMAGE=${artifact_image}"
    --build-arg "PACKAGE_BASE_STAGE=${package_base_stage}"
    --build-arg "ARTIFACT_PLATFORM=$(runtime_artifact_platform "${arch}")"
    --build-arg "BUILD_MODE=${ARTIFACT_BUILD_MODE}"
    --build-arg "TARGET_ARCH=${arch}"
  )
}

append_wrapper_build_args() {
  local -n _awba_out=$1
  local arch="$2" parent_image="$3"
  _awba_out+=(
    --build-arg "BASE_IMAGE=${parent_image}"
    --build-arg "BUILD_MODE=native"
    --build-arg "TARGET_ARCH=${arch}"
    --build-arg "TORCH_APP_MODE=${TORCH_APP_MODE:-all}"
    --build-arg "BUILD_TYPE=${BUILD_TYPE:-Release}"
  )
  # Documented operator overrides (see runtime_shared_usage_env_overrides);
  # forwarded only when set so the Dockerfile.torch defaults stay authoritative.
  append_optional_build_arg _awba_out ONNX_PACKAGE "${ONNX_PACKAGE:-}"
  append_optional_build_arg _awba_out PYTORCH_EXTRA "${PYTORCH_EXTRA:-}"
}

runtime_build_package_image() {
  local arch="$1"
  local tag parent_image parent_context_dir
  local artifact_image artifact_context_ref artifact_context_mode package_base_stage
  local -a build_args=()

  tag="$(runtime_package_tag "${arch}")"
  append_common_build_args build_args
  append_runtime_accelerator_build_args build_args

  if runtime_use_local_artifact_context; then
    artifact_context_mode="${ARTIFACT_CONTEXT_MODE:-oci}"
    artifact_context_ref="$(runtime_artifact_context_ref "${arch}" "${artifact_context_mode}")"
    artifact_image="runtime_artifact"
    package_base_stage="package-image"
    build_args+=(--build-context "runtime_artifact=${artifact_context_ref}")
  else
    artifact_image="$(runtime_artifact_image_ref "${arch}")"
    package_base_stage="package-image"
  fi

  _runtime_resolve_parent_context base "${arch}" parent_image parent_context_dir build_args

  if is_dry_run; then
    log "[DRY RUN] would build package image ${tag} (platform linux/${arch})"
    return 0
  fi

  append_package_build_args build_args "${arch}" "${parent_image}" "${artifact_image}" "${package_base_stage}"

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    "${_rb_pull}" \
    --platform "linux/${arch}" \
    --target "${PACKAGE_DOCKERFILE_TARGET:-package}" \
    -t "${tag}" \
    -f "${PACKAGE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    . || return 1

  _runtime_finish_stage package "${arch}" "${tag}" base
}

_runtime_build_wrapper() {
  local arch="$1"
  local -n _wrapper_tag_out=$2
  local -n _wrapper_parent_image_out=$3
  local -n _wrapper_build_args_out=$4

  _wrapper_tag_out="$(runtime_wrapper_tag "${arch}")"
  append_common_build_args _wrapper_build_args_out
  append_runtime_accelerator_build_args _wrapper_build_args_out

  local parent_context_dir
  _runtime_resolve_parent_context package "${arch}" _wrapper_parent_image_out parent_context_dir _wrapper_build_args_out

  if is_dry_run; then
    log "[DRY RUN] would build wrapper image ${_wrapper_tag_out} (platform linux/${arch})"
    return 0
  fi

  append_wrapper_build_args _wrapper_build_args_out "${arch}" "${_wrapper_parent_image_out}"

  local _rb_pull="--pull=true"
  runtime_pushes_intermediate_images || _rb_pull="--pull=false"
  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    "${_rb_pull}" \
    --platform "linux/${arch}" \
    -t "${_wrapper_tag_out}" \
    -f "${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}" \
    "${_wrapper_build_args_out[@]}" \
    . || return 1

  runtime_remove_stage_context package "${arch}"
}

runtime_build_wrapper_image() {
  local arch="$1"
  local tag parent_image
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  if is_dry_run; then
    log "[DRY RUN] would push wrapper image ${tag}"
    return 0
  fi

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}"
  fi
}

runtime_build_wrapper_rootfs() {
  local arch="$1"
  local rootfs_dir="$2"
  local tag parent_image artifact_dir
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  if is_dry_run; then
    log "[DRY RUN] would export rootfs from ${tag} to ${rootfs_dir} and push"
    return 0
  fi

  artifact_dir="$(dirname "${rootfs_dir}")"
  export_rootfs_from_image "${NERDCTL_BIN:-nerdctl}" "${tag}" "${artifact_dir}"

  if runtime_pushes_wrapper_images; then
    runtime_push_tag "${tag}"
  fi
}

runtime_build_chain() {
  local arch="$1"
  local rootfs_dir="${2:-}"

  # EXPLICIT `|| return 1` on every step (same hazard as cross_stage_run):
  # this function is invoked via run_parallel_arch_loop's `if !`, which
  # disables set -e for the whole call tree — without these, a failed base or
  # package build fell through to the next step and the lane reported success
  # with nothing built.
  runtime_build_base_image "${arch}" || return 1
  runtime_build_package_image "${arch}" || return 1

  if [ -n "${rootfs_dir}" ]; then
    runtime_build_wrapper_rootfs "${arch}" "${rootfs_dir}" || return 1
    return 0
  fi

  runtime_build_wrapper_image "${arch}" || return 1
}

runtime_write_artifact_metadata() {
  local arch="$1"
  local output_dir="$2"

  mkdir -p "${output_dir}"
  cat > "${output_dir}/artifact.env" <<EOF
TARGET_ARCH=${arch}
SOURCE_IMAGE=$(runtime_wrapper_tag "${arch}")
PACKAGE_IMAGE=$(runtime_package_tag "${arch}")
BASE_IMAGE=$(runtime_base_tag "${arch}")
ARTIFACT_IMAGE=$(runtime_artifact_image_ref "${arch}")
EOF
}

runtime_shared_usage_env_overrides() {
  cat <<'EOF'
Environment overrides:
  NERDCTL_BIN                  nerdctl executable to use
  BUILDKIT_HOST                Optional BuildKit socket/address passed to nerdctl build
  TARGET_ARCHES                Comma-separated architecture list
  TARGET_ARCH                  Alias for TARGET_ARCHES
  ARCHITECTURES                Alias for TARGET_ARCHES
  RUNTIME_USE_LOCAL_CONTEXT_CHAIN
                                true/false/auto (default: auto)
  RUNTIME_CONTEXT_ROOT         Temporary directory root for local stage handoff
  BASE_DOCKERFILE_PATH         Base Dockerfile path
  BASE_PARENT_IMAGE            Optional parent image passed as BASE_IMAGE to the
                                selected base Dockerfile (for example a GPU base)
  PACKAGE_DOCKERFILE_PATH      Package Dockerfile path
  WRAPPER_DOCKERFILE_PATH      Final wrapper (torch) Dockerfile path
  TORCH_APP_MODE               TORCH_APP_MODE passed to linux/Dockerfile.torch
  ENABLE_NVIDIA                Optional accelerator flag passed to package/torch/wrapper builds
  ENABLE_AMD                   Optional accelerator flag passed to package/torch/wrapper builds
  ONNX_PACKAGE                 Optional torch ONNX package override
  PYTORCH_EXTRA                Optional torch PyTorch extra override
  USE_FAST_UBUNTU_MIRROR       Set to true to replace archive/security/ports Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL       Mirror URL used when the fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL used when the fast mirror is enabled
EOF
}
