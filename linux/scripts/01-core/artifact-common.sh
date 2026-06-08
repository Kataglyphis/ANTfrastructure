#!/usr/bin/env bash

_ARTIFACT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUILDKIT_HOST="${BUILDKIT_HOST:-}"
RUNTIME_CONTEXT_ROOT="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/runtime-build-contexts}"

# Load canonical version defaults.  Already-set environment variables take
# precedence so orchestrator overrides still work.
if [ -z "${_VERSIONS_ENV_LOADED:-}" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  [ -f "${_ARTIFACT_COMMON_DIR}/versions.env" ] && source "${_ARTIFACT_COMMON_DIR}/versions.env"
  set +a
  _VERSIONS_ENV_LOADED=1
fi

# Load logging helpers (info, warn, err, log, die).
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/platform.sh" ] && source "${_ARTIFACT_COMMON_DIR}/platform.sh"
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/logging.sh" ] && source "${_ARTIFACT_COMMON_DIR}/logging.sh"

canonical_target_arch() {
  arch_normalize "$1" || return 1
}

normalize_target_arches() {
  local raw_arches="$1"
  local raw_arch normalized_arch
  local -a normalized_arches=()

  for raw_arch in ${raw_arches//,/ }; do
    normalized_arch="$(canonical_target_arch "${raw_arch}")" || {
      printf '[ERROR] Unsupported target architecture: %s\n' "${raw_arch}" >&2
      return 1
    }
    normalized_arches+=("${normalized_arch}")
  done

  if [ "${#normalized_arches[@]}" -eq 0 ]; then
    printf '[ERROR] At least one target architecture is required\n' >&2
    return 1
  fi

  printf '%s' "${normalized_arches[*]}" | tr ' ' ','
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

append_buildkit_host_arg() {
  local -n out_args_ref=$1

  if [ -n "${BUILDKIT_HOST}" ]; then
    out_args_ref+=(--buildkit-host "${BUILDKIT_HOST}")
  fi
}

append_mirror_build_args() {
  local -n out_args_ref=$1
  local use_fast_mirror="${2:-${USE_FAST_UBUNTU_MIRROR:-false}}"
  local archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}}"
  local ports_url="${4:-${FAST_UBUNTU_PORTS_MIRROR_URL:-}}"

  out_args_ref+=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${use_fast_mirror}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${archive_url}"
  )

  if [ -n "${ports_url}" ]; then
    out_args_ref+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${ports_url}")
  fi
}

append_optional_build_arg() {
  local -n out_args_ref=$1
  local arg_name="$2"
  local arg_value="${3:-}"

  if [ -n "${arg_value}" ]; then
    out_args_ref+=(--build-arg "${arg_name}=${arg_value}")
  fi
}

append_runtime_base_parent_build_arg() {
  append_optional_build_arg "$1" BASE_IMAGE "${BASE_PARENT_IMAGE:-}"
}

append_runtime_accelerator_build_args() {
  append_optional_build_arg "$1" ENABLE_NVIDIA "${ENABLE_NVIDIA:-}"
  append_optional_build_arg "$1" ENABLE_AMD "${ENABLE_AMD:-}"
}

append_runtime_torch_build_args() {
  append_runtime_accelerator_build_args "$1"
  append_optional_build_arg "$1" ONNX_PACKAGE "${ONNX_PACKAGE:-}"
  append_optional_build_arg "$1" PYTORCH_EXTRA "${PYTORCH_EXTRA:-}"
}

image_exists() {
  local nerdctl_bin image_ref

  if [ "$#" -eq 1 ]; then
    nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
    image_ref="$1"
  else
    nerdctl_bin="$1"
    image_ref="$2"
  fi

  "${nerdctl_bin}" image inspect "${image_ref}" >/dev/null 2>&1
}

# Resolve the registry-resolvable manifest digest of a pushed tag and print a
# digest-pinned reference like "repo@sha256:...".
#
# This intentionally uses `nerdctl manifest inspect --verbose` (which reports the
# digest of the manifest as it exists in the registry) rather than the local
# image store's RepoDigests. On this host BuildKit pushes a converted
# `docker.v2+json` manifest whose digest differs from the local OCI manifest, so
# RepoDigests is NOT registry-resolvable and must not be used for `FROM` pinning.
registry_pin_ref() {
  local nerdctl_bin image_ref

  if [ "$#" -eq 1 ]; then
    nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
    image_ref="$1"
  else
    nerdctl_bin="$1"
    image_ref="$2"
  fi

  local repo digest
  repo="${image_ref%:*}"
  digest="$("${nerdctl_bin}" manifest inspect --verbose "${image_ref}" 2>/dev/null \
    | python3 -c 'import sys, json
data = json.load(sys.stdin)
entry = data[0] if isinstance(data, list) else data
print(entry["Descriptor"]["digest"])' 2>/dev/null)"

  if [ -z "${digest}" ]; then
    printf '[ERROR] Could not resolve registry digest for %s\n' "${image_ref}" >&2
    return 1
  fi

  printf '%s@%s' "${repo}" "${digest}"
}

run_nerdctl_build() {
  local nerdctl_bin="$1"
  shift

  local -a build_cmd=("${nerdctl_bin}" build)
  append_buildkit_host_arg build_cmd
  build_cmd+=("$@")
  run "${build_cmd[@]}"
}

run_nerdctl_build_to_tag() {
  local nerdctl_bin="$1"
  local tag="$2"
  shift 2

  local -a build_cmd=("${nerdctl_bin}" build)
  append_buildkit_host_arg build_cmd
  build_cmd+=(-t "${tag}" "$@")
  run "${build_cmd[@]}"
}

pull_platform_image() {
  local nerdctl_bin="$1"
  local platform="$2"
  local image_ref="$3"

  run "${nerdctl_bin}" pull --platform "${platform}" "${image_ref}"
}

export_rootfs_from_image() {
  local nerdctl_bin="$1"
  local tag="$2"
  local artifact_dir="$3"
  shift 3

  local rootfs_dir="${artifact_dir}/rootfs"
  local cid=""

  rm -rf "${artifact_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$("${nerdctl_bin}" create "${tag}" /bin/true)"
  cleanup_container() {
    if [ -n "${cid}" ]; then
      "${nerdctl_bin}" rm -f "${cid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_container RETURN

  "${nerdctl_bin}" export "${cid}" | tar -xpf - -C "${rootfs_dir}"

  if [ "$#" -gt 0 ]; then
    : > "${artifact_dir}/artifact.env"
    while [ "$#" -gt 0 ]; do
      printf '%s\n' "$1" >> "${artifact_dir}/artifact.env"
      shift
    done
  fi

  cleanup_container
  trap - RETURN
}

export_image_rootfs_dir() {
  local nerdctl_bin="$1"
  local tag="$2"
  local rootfs_dir="$3"
  local cid=""

  rm -rf "${rootfs_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$(${nerdctl_bin} create "${tag}" /bin/true)"
  cleanup_container() {
    if [ -n "${cid}" ]; then
      "${nerdctl_bin}" rm -f "${cid}" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup_container RETURN

  "${nerdctl_bin}" export "${cid}" | tar -xpf - -C "${rootfs_dir}"

  cleanup_container
  trap - RETURN
}

export_image_to_oci_layout() {
  local nerdctl_bin="$1"
  local tag="$2"
  local dest_dir="$3"

  rm -rf "${dest_dir}"
  mkdir -p "${dest_dir}"

  printf '+ %q save %q | tar -xf - -C %q\n' "${nerdctl_bin}" "${tag}" "${dest_dir}"
  "${nerdctl_bin}" save "${tag}" | tar -xf - -C "${dest_dir}"
}

remove_local_image_if_exists() {
  local nerdctl_bin="$1"
  local image_ref="$2"

  image_exists "${nerdctl_bin}" "${image_ref}" || return 0
  run "${nerdctl_bin}" rmi "${image_ref}"
}

runtime_stage_context_ref() {
  local kind="$1"
  local arch="$2"
  local context_dir

  context_dir="$(runtime_stage_context_dir "${kind}" "${arch}")"
  printf '%s' "oci-layout://${context_dir}"
}

runtime_pushes_wrapper_images() {
  [ "${PUSH_IMAGES:-0}" -eq 1 ]
}

runtime_pushes_intermediate_images() {
  runtime_pushes_wrapper_images && [ "${PUSH_INTERMEDIATE_IMAGES:-0}" -eq 1 ]
}

runtime_use_local_context_chain() {
  case "${RUNTIME_USE_LOCAL_CONTEXT_CHAIN:-auto}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    auto|"") ! runtime_pushes_intermediate_images ;;
    *)
      printf '[ERROR] Unsupported RUNTIME_USE_LOCAL_CONTEXT_CHAIN value: %s\n' "${RUNTIME_USE_LOCAL_CONTEXT_CHAIN}" >&2
      return 1
      ;;
  esac
}

runtime_prepare_local_context_chain() {
  runtime_use_local_context_chain || return 0

  if [ -n "${RUNTIME_CONTEXT_WORKDIR:-}" ]; then
    return 0
  fi

  mkdir -p "${RUNTIME_CONTEXT_ROOT}"
  RUNTIME_CONTEXT_WORKDIR="$(mktemp -d "${RUNTIME_CONTEXT_ROOT}/runtime-flow.XXXXXX")"
}

runtime_cleanup_local_context_chain() {
  if [ -n "${RUNTIME_CONTEXT_WORKDIR:-}" ] && [ -d "${RUNTIME_CONTEXT_WORKDIR}" ]; then
    rm -rf "${RUNTIME_CONTEXT_WORKDIR}"
  fi

  RUNTIME_CONTEXT_WORKDIR=""
}

runtime_use_local_stage_context_outputs() {
  runtime_use_local_context_chain || return 1
  # When we are not pushing intermediate images the entire intermediate
  # pipeline stays in local OCI-layout directories — only the final
  # wrapper image is tagged and pushed.
  ! runtime_pushes_intermediate_images
}

runtime_install_local_context_cleanup_trap() {
  trap 'runtime_cleanup_local_context_chain' EXIT
  trap 'exit 130' INT TERM
}

runtime_stage_context_dir() {
  local kind="$1"
  local arch="$2"

  runtime_prepare_local_context_chain || return 1
  printf '%s' "${RUNTIME_CONTEXT_WORKDIR}/${kind}-${arch}"
}

runtime_remove_stage_context() {
  local kind="$1"
  local arch="$2"
  local context_dir

  runtime_use_local_context_chain || return 0

  if [ -z "${RUNTIME_CONTEXT_WORKDIR:-}" ]; then
    return 0
  fi

  context_dir="${RUNTIME_CONTEXT_WORKDIR}/${kind}-${arch}"
  rm -rf "${context_dir}"
}

runtime_refresh_stage_context() {
  local kind="$1"
  local arch="$2"
  local image_ref="$3"
  local context_dir

  runtime_use_local_context_chain || return 0
  context_dir="$(runtime_stage_context_dir "${kind}" "${arch}")"
  export_image_rootfs_dir "${NERDCTL_BIN:-nerdctl}" "${image_ref}" "${context_dir}"
}

runtime_require_image_prefix() {
  if [ -z "${RUNTIME_IMAGE_PREFIX:-}" ]; then
    printf '[ERROR] RUNTIME_IMAGE_PREFIX is required\n' >&2
    return 1
  fi
}

runtime_base_tag() {
  local arch="$1"

  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-base-${arch}"
}

runtime_package_tag() {
  local arch="$1"

  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-package-${arch}"
}

runtime_wrapper_tag() {
  local arch="$1"

  runtime_require_image_prefix || return 1
  printf '%s' "${RUNTIME_IMAGE_PREFIX}-${arch}"
}

runtime_artifact_platform() {
  local arch="$1"

  case "${ARTIFACT_BUILD_MODE:-cross}" in
    cross) printf '%s' "linux/amd64" ;;
    native) printf '%s' "linux/${arch}" ;;
    *)
      printf '[ERROR] Unsupported artifact build mode: %s\n' "${ARTIFACT_BUILD_MODE}" >&2
      return 1
      ;;
  esac
}

runtime_artifact_image_ref() {
  local arch="$1"

  case "${ARTIFACT_BUILD_MODE:-cross}" in
    cross) printf '%s' "${ARTIFACT_IMAGE_PREFIX}-${arch}" ;;
    native) printf '%s' "${ARTIFACT_IMAGE_PREFIX}" ;;
    *)
      printf '[ERROR] Unsupported artifact build mode: %s\n' "${ARTIFACT_BUILD_MODE}" >&2
      return 1
      ;;
  esac
}

runtime_use_local_artifact_context() {
  [ -n "${ARTIFACT_CONTEXT_ROOT:-}" ]
}

runtime_artifact_context_dir() {
  local arch="$1"

  if [ -z "${ARTIFACT_CONTEXT_ROOT:-}" ]; then
    printf '[ERROR] ARTIFACT_CONTEXT_ROOT is required for local artifact contexts\n' >&2
    return 1
  fi

  printf '%s' "${ARTIFACT_CONTEXT_ROOT%/}/${arch}"
}

runtime_artifact_context_ref() {
  local arch="$1"
  local mode="${2:-oci}"
  local context_dir

  context_dir="$(runtime_artifact_context_dir "${arch}")" || return 1
  case "${mode}" in
    oci)
      if [ ! -f "${context_dir}/index.json" ] || [ ! -f "${context_dir}/oci-layout" ]; then
        printf '[ERROR] Missing OCI artifact context for %s: %s\n' "${arch}" "${context_dir}" >&2
        return 1
      fi
      printf '%s' "oci-layout://${context_dir}"
      ;;
    dir)
      if [ ! -d "${context_dir}" ]; then
        printf '[ERROR] Missing directory artifact context for %s: %s\n' "${arch}" "${context_dir}" >&2
        return 1
      fi
      printf '%s' "${context_dir}"
      ;;
    *)
      printf '[ERROR] Unsupported artifact context mode for %s: %s\n' "${arch}" "${mode}" >&2
      return 1
      ;;
  esac
}

# Resolve a parent stage as either a remote image tag or a local
# OCI-layout build context. Sets the out variables:
#   parent_image_var   -> base image name to pass as --build-arg BASE_IMAGE
#   parent_context_var -> local OCI context dir (only when local)
# Appends any --build-context args needed for local mode to the build_args array.
_runtime_resolve_parent_context() {
  local parent_kind="$1"
  local arch="$2"
  local -n _out_image_ref=$3
  local -n _out_context_dir=$4
  local -n _out_build_args=$5

  if runtime_use_local_stage_context_outputs; then
    _out_context_dir="$(runtime_stage_context_dir "${parent_kind}" "${arch}")"
    _out_image_ref="runtime_${parent_kind}"
    # The export format differs per stage and the build-context reference MUST
    # match it. `base` is exported as a flat rootfs directory
    # (export_image_rootfs_dir) and is consumed as a plain directory context.
    # `package` is exported as an OCI image layout (export_image_to_oci_layout)
    # in _runtime_finish_stage; it preserves the image config (PATH, ENV,
    # SHELL, /usr/bin/bash), which `FROM runtime_package` in Dockerfile.torch
    # depends on. An OCI layout consumed as a plain directory context would
    # hand BuildKit the layout's blobs/index.json as a rootfs and break
    # `FROM` (exec: "bash": executable file not found). Reference it via the
    # oci-layout:// scheme so BuildKit resolves it as an image.
    local _parent_context_ref="${_out_context_dir}"
    case "${parent_kind}" in
      base)    _parent_context_ref="${_out_context_dir}" ;;
      package) _parent_context_ref="oci-layout://${_out_context_dir}" ;;
    esac
    _out_build_args+=(--build-context "runtime_${parent_kind}=${_parent_context_ref}")
  else
    _out_context_dir=""
    case "${parent_kind}" in
      base)    _out_image_ref="$(runtime_base_tag "${arch}")" ;;
      package) _out_image_ref="$(runtime_package_tag "${arch}")" ;;
      *)       return 1 ;;
    esac
  fi
}

# Post-build: export to OCI layout locally, or push remotely, then clean up.
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
      run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
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
  local tag context_dir parent_image parent_context
  local -a build_args=()

  tag="$(runtime_base_tag "${arch}")"
  append_mirror_build_args build_args "${USE_FAST_UBUNTU_MIRROR:-false}" "${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}" "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
  append_runtime_base_parent_build_arg build_args

  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=true \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${BASE_DOCKERFILE_PATH}" \
    "${build_args[@]}" \
    .

  if runtime_use_local_stage_context_outputs; then
    context_dir="$(runtime_stage_context_dir base "${arch}")"
    export_image_rootfs_dir "${NERDCTL_BIN:-nerdctl}" "${tag}" "${context_dir}"
    remove_local_image_if_exists "${NERDCTL_BIN:-nerdctl}" "${tag}"
    return 0
  fi

  if runtime_pushes_intermediate_images; then
    run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
  fi

  runtime_refresh_stage_context base "${arch}" "${tag}"
}

runtime_build_package_image() {
  local arch="$1"
  local tag parent_image parent_context_dir
  local artifact_image artifact_context_ref artifact_context_mode package_base_stage
  local -a build_args=()

  tag="$(runtime_package_tag "${arch}")"
  append_mirror_build_args build_args "${USE_FAST_UBUNTU_MIRROR:-false}" "${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}" "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
  append_runtime_accelerator_build_args build_args

  if runtime_use_local_artifact_context; then
    artifact_context_mode="${ARTIFACT_CONTEXT_MODE:-dir}"
    artifact_context_ref="$(runtime_artifact_context_ref "${arch}" "${artifact_context_mode}")"
    if [ "${artifact_context_mode}" = "dir" ]; then
      artifact_image="scratch"
      package_base_stage="artifact-source-local"
      build_args+=(--build-context "runtime_artifact=${artifact_context_ref}")
      build_args+=(--build-arg "ARTIFACT_SOURCE_STAGE=artifact-source-local")
    else
      artifact_image="runtime_artifact"
      package_base_stage="package-image"
      build_args+=(--build-context "runtime_artifact=${artifact_context_ref}")
    fi
  else
    artifact_image="$(runtime_artifact_image_ref "${arch}")"
    package_base_stage="package-image"
  fi

  _runtime_resolve_parent_context base "${arch}" parent_image parent_context_dir build_args

  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=false \
    --platform "linux/${arch}" \
    -t "${tag}" \
    -f "${PACKAGE_DOCKERFILE_PATH}" \
    --build-arg "BASE_IMAGE=${parent_image}" \
    --build-arg "ARTIFACT_IMAGE=${artifact_image}" \
    --build-arg "PACKAGE_BASE_STAGE=${package_base_stage}" \
    --build-arg "ARTIFACT_PLATFORM=$(runtime_artifact_platform "${arch}")" \
    --build-arg "BUILD_MODE=${ARTIFACT_BUILD_MODE}" \
    --build-arg "TARGET_ARCH=${arch}" \
    "${build_args[@]}" \
    .

  _runtime_finish_stage package "${arch}" "${tag}" base
}

_runtime_build_wrapper() {
  local arch="$1"
  local -n _wrapper_tag_out=$2
  local -n _wrapper_parent_image_out=$3
  local -n _wrapper_build_args_out=$4

  _wrapper_tag_out="$(runtime_wrapper_tag "${arch}")"
  append_mirror_build_args _wrapper_build_args_out "${USE_FAST_UBUNTU_MIRROR:-false}" "${FAST_UBUNTU_MIRROR_URL:-https://archive.ubuntu.com/ubuntu/}" "${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
  append_runtime_accelerator_build_args _wrapper_build_args_out

  local parent_context_dir
  _runtime_resolve_parent_context package "${arch}" _wrapper_parent_image_out parent_context_dir _wrapper_build_args_out

  run_nerdctl_build "${NERDCTL_BIN:-nerdctl}" \
    --pull=false \
    --platform "linux/${arch}" \
    -t "${_wrapper_tag_out}" \
    -f "${WRAPPER_DOCKERFILE_PATH:-linux/Dockerfile.torch}" \
    --build-arg "BASE_IMAGE=${_wrapper_parent_image_out}" \
    --build-arg "BUILD_MODE=native" \
    --build-arg "TARGET_ARCH=${arch}" \
    --build-arg "TORCH_APP_MODE=${TORCH_APP_MODE:-all}" \
    --build-arg "BUILD_TYPE=${BUILD_TYPE:-Release}" \
    "${_wrapper_build_args_out[@]}" \
    .

  runtime_remove_stage_context package "${arch}"
}

runtime_build_wrapper_image() {
  local arch="$1"
  local tag parent_image
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  if runtime_pushes_wrapper_images; then
    run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
  fi
}

runtime_build_wrapper_rootfs() {
  local arch="$1"
  local rootfs_dir="$2"
  local tag parent_image artifact_dir
  local -a build_args=()

  _runtime_build_wrapper "${arch}" tag parent_image build_args

  artifact_dir="$(dirname "${rootfs_dir}")"
  export_rootfs_from_image "${NERDCTL_BIN:-nerdctl}" "${tag}" "${artifact_dir}"

  if runtime_pushes_wrapper_images; then
    run "${NERDCTL_BIN:-nerdctl}" push "${tag}"
  fi
}

runtime_build_chain() {
  local arch="$1"
  local rootfs_dir="${2:-}"

  runtime_build_base_image "${arch}"
  runtime_build_package_image "${arch}"

  if [ -n "${rootfs_dir}" ]; then
    runtime_build_wrapper_rootfs "${arch}" "${rootfs_dir}"
    return 0
  fi

  runtime_build_wrapper_image "${arch}"
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

# ==============================================================================
# Shared CLI argument parsing for cross-chain orchestrator scripts.
# Call this from the argument loop in build-cross-chain.sh,
# build-cross-compiler.sh, and build-sdk-artifacts.sh.
#
# Receives namerefs for the shared variables, then $1 $2 from the caller's loop.
#
# Return values:
#   1  — consumed a single-arg flag (caller should shift 1)
#   2  — consumed a two-arg flag (caller should shift 2)
#   0  — flag not recognized (caller should handle it)
#   255 — --help requested (caller should print usage and exit)
# ==============================================================================
parse_shared_orchestrator_args() {
  local -n _psoa_target_arches=$1
  local -n _psoa_use_fast_mirror=$2
  local -n _psoa_fast_mirror_url=$3
  local -n _psoa_fast_ports_url=$4
  local -n _psoa_image_repo=$5
  local -n _psoa_vulkan_version=$6
  local -n _psoa_push=$7
  shift 7 || true
  local arg="$1" val="$2"

  case "${arg}" in
    --target-arches|--architectures)
      _psoa_target_arches="${val}"; return 2 ;;
    --image-repo)
      _psoa_image_repo="${val}"; return 2 ;;
    --vulkan-version)
      _psoa_vulkan_version="${val}"; return 2 ;;
    --fast-ubuntu-mirror)
      _psoa_use_fast_mirror=true; return 1 ;;
    --fast-ubuntu-mirror-url)
      _psoa_use_fast_mirror=true; _psoa_fast_mirror_url="${val}"; return 2 ;;
    --fast-ubuntu-ports-mirror-url)
      _psoa_use_fast_mirror=true; _psoa_fast_ports_url="${val}"; return 2 ;;
    --push)
      _psoa_push=1; return 1 ;;
    -h|--help)
      return 255 ;;
    *)
      return 0 ;;
  esac
}

# ==============================================================================
# Shared CLI argument parsing for runtime build scripts.
# Call this from the argument loop in build-runtime-artifacts.sh and
# build-runtime-manifest.sh to handle their nearly identical flag sets.
#
# Receives: name-refs for all shared variables, then $1 $2 from the caller's loop.
#
# Return values:
#   1  — consumed a single-arg flag (caller should shift 1)
#   2  — consumed a two-arg flag (caller should shift 2)
#   0  — flag not recognized (caller should handle it)
#   255 — --help requested (caller should print usage and exit)
# ==============================================================================
parse_shared_runtime_args() {
  local -n _target_arches=$1
  local -n _artifact_image_prefix=$2
  local -n _artifact_build_mode=$3
  local -n _base_dockerfile=$4
  local -n _package_dockerfile=$5
  local -n _wrapper_dockerfile=$6
  local -n _torch_app_mode=$7
  local -n _use_fast_mirror=$8
  local -n _fast_mirror_url=$9
  local -n _fast_ports_url=${10}
  local -n _push_intermediate=${11}
  shift 11 || true
  local arg="$1" val="$2"

  case "${arg}" in
    --architectures|--target-arches)
      _target_arches="${val}"; return 2 ;;
    --artifact-image-prefix)
      _artifact_image_prefix="${val}"; return 2 ;;
    --artifact-build-mode)
      _artifact_build_mode="${val}"; return 2 ;;
    --base-dockerfile)
      _base_dockerfile="${val}"; return 2 ;;
    --package-dockerfile)
      _package_dockerfile="${val}"; return 2 ;;
    --wrapper-dockerfile|--torch-dockerfile)
      _wrapper_dockerfile="${val}"; return 2 ;;
    --torch-app-mode)
      _torch_app_mode="${val}"; return 2 ;;
    --fast-ubuntu-mirror)
      _use_fast_mirror=true; return 1 ;;
    --fast-ubuntu-mirror-url)
      _use_fast_mirror=true; _fast_mirror_url="${val}"; return 2 ;;
    --fast-ubuntu-ports-mirror-url)
      _use_fast_mirror=true; _fast_ports_url="${val}"; return 2 ;;
    --push-all)
      _push_intermediate=1; return 1 ;;
    -h|--help)
      return 255 ;;
    *)
      return 0 ;;
  esac
}
