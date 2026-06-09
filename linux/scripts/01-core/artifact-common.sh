#!/usr/bin/env bash

_ARTIFACT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME_CONTEXT_ROOT="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/runtime-build-contexts}"

# Load common.sh (versions.env, platform.sh, logging.sh, ubuntu-mirror.sh,
# downloads.sh, parallelism.sh).  common.sh has its own _VERSIONS_ENV_LOADED
# guard so double-sourcing is safe.
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/common.sh" ] && source "${_ARTIFACT_COMMON_DIR}/common.sh"

# canonical_target_arch() is provided by platform.sh (sourced above)

normalize_target_arches() {
  local raw_arches="$1"

  local result
  result="$(arch_list_csv_normalize "${raw_arches}")" || {
    printf '[ERROR] At least one valid target architecture is required (got: %s)\n' "${raw_arches}" >&2
    return 1
  }

  printf '%s' "${result}"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

# Like run() but does NOT echo the command. Use when build args may contain
# secrets (e.g. GITHUB_TOKEN, registry credentials) that must not appear in logs.
run_quiet() {
  "$@"
}

append_buildkit_host_arg() {
  local -n out_args_ref=$1

  if [ -n "${BUILDKIT_HOST:-}" ]; then
    out_args_ref+=(--buildkit-host "${BUILDKIT_HOST}")
  fi
}

append_mirror_build_args() {
  local -n out_args_ref=$1
  local use_fast_mirror="${2:-${USE_FAST_UBUNTU_MIRROR:-false}}"
  local archive_url="${3:-${FAST_UBUNTU_MIRROR_URL:-${FAST_UBUNTU_MIRROR_URL_DEFAULT:-https://archive.ubuntu.com/ubuntu/}}}"
  local ports_url="${4:-${FAST_UBUNTU_PORTS_MIRROR_URL:-}}"

  out_args_ref+=(
    --build-arg "USE_FAST_UBUNTU_MIRROR=${use_fast_mirror}"
    --build-arg "FAST_UBUNTU_MIRROR_URL=${archive_url}"
  )

  if [ -n "${ports_url}" ]; then
    out_args_ref+=(--build-arg "FAST_UBUNTU_PORTS_MIRROR_URL=${ports_url}")
  fi
}

append_common_build_args() {
  local _acba_name="$1"
  append_mirror_build_args "${_acba_name}" "${2:-}" "${3:-}" "${4:-}"
  append_version_build_args "${_acba_name}"
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

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[ERROR] python3 is required for registry digest resolution\n' >&2
    return 1
  fi

  local digest_script="${_ARTIFACT_COMMON_DIR}/registry-digest.py"
  if [ ! -f "${digest_script}" ]; then
    printf '[ERROR] registry-digest.py not found at %s\n' "${digest_script}" >&2
    return 1
  fi

  digest="$("${nerdctl_bin}" manifest inspect --verbose "${image_ref}" 2>/dev/null \
    | python3 "${digest_script}" 2>/dev/null)"

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

  run_nerdctl_build "${nerdctl_bin}" -t "${tag}" "$@"
}

pull_platform_image() {
  local nerdctl_bin="$1"
  local platform="$2"
  local image_ref="$3"

  run "${nerdctl_bin}" pull --platform "${platform}" "${image_ref}"
}

_export_container_rootfs() {
  local nerdctl_bin="$1"
  local tag="$2"
  local rootfs_dir="$3"
  local cid=""

  rm -rf "${rootfs_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$("${nerdctl_bin}" create "${tag}" /bin/true)"
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

export_rootfs_from_image() {
  local nerdctl_bin="$1"
  local tag="$2"
  local artifact_dir="$3"
  shift 3

  local rootfs_dir="${artifact_dir}/rootfs"
  _export_container_rootfs "${nerdctl_bin}" "${tag}" "${rootfs_dir}"

  if [ "$#" -gt 0 ]; then
    : > "${artifact_dir}/artifact.env"
    while [ "$#" -gt 0 ]; do
      printf '%s\n' "$1" >> "${artifact_dir}/artifact.env"
      shift
    done
  fi
}

export_image_rootfs_dir() {
  _export_container_rootfs "$@"
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

runtime_stage_export_is_oci() {
  local kind="$1"
  case "${kind}" in
    base) return 1 ;;    # plain rootfs directory (host workaround: cannot consume two OCI contexts)
    package|wrapper) return 0 ;;  # OCI image layout (preserves image config for FROM)
    *) return 1 ;;
  esac
}

# Resolve a parent stage as either a remote image tag or a local
# build context. Sets the out variables:
#   parent_image_var   -> base image name to pass as --build-arg BASE_IMAGE
#   parent_context_var -> local context dir (only when local)
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
    local _parent_context_ref="${_out_context_dir}"
    if runtime_stage_export_is_oci "${parent_kind}"; then
      # OCI layout preserves image config (PATH, ENV, SHELL, /usr/bin/bash)
      # which FROM depends on.  Reference via oci-layout:// so BuildKit
      # resolves it as an image, not a plain rootfs directory.
      _parent_context_ref="oci-layout://${_out_context_dir}"
    fi
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

# ==============================================================================
# Cross-chain tag name functions.
# Centralized tag naming so orchestrators and helpers stay in sync.
#
# NOTE: Tag naming is not fully consistent across stages:
#   :base                     (no -cross- suffix)
#   :compiler-cross-amd64     (has -cross- suffix on amd64-only image)
#   :sdk-artifact-<arch>      (uses "artifact" instead of "cross")
#   :media-cross-<arch>       (standard pattern)
#   :android-cross-<arch>     (standard pattern)
# Future: standardize to :cross-<stage>-<arch> for all stages.
# ==============================================================================
cross_base_tag()              { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:base"; }
cross_compiler_tag()          { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:compiler-cross-amd64"; }
cross_sdk_tag()               { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:sdk-artifact-${1}"; }
cross_media_tag()             { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:media-cross-${1}"; }
cross_android_tag()           { printf '%s' "${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}:android-cross-${1}"; }

# ==============================================================================
# Append --build-arg VAR=$VAR for every version tracked in versions.env.
# ==============================================================================
_auto_discover_version_build_arg_vars() {
  local versions_file="${_ARTIFACT_COMMON_DIR}/versions.env"
  [ -f "${versions_file}" ] || return 0
  grep -E '^[A-Z][A-Z0-9_]*(_VERSION|_RELEASE|_MAJOR_MINOR|_MAJOR)=' "${versions_file}" \
    | cut -d= -f1
}

if [ -z "${_VERSION_BUILD_ARG_VARS_CACHED:-}" ]; then
  _VERSION_BUILD_ARG_VARS=()
  while IFS= read -r varname; do
    [ -n "${varname}" ] && _VERSION_BUILD_ARG_VARS+=("${varname}")
  done < <(_auto_discover_version_build_arg_vars)
  _VERSION_BUILD_ARG_VARS_CACHED=1
fi

append_version_build_args() {
  local _avba_name="$1"
  local var_name
  for var_name in "${_VERSION_BUILD_ARG_VARS[@]}"; do
    if [ -n "${!var_name:-}" ]; then
      append_optional_build_arg "${_avba_name}" "${var_name}" "${!var_name}"
    fi
  done
}

# ==============================================================================
# Source sub-modules (must follow all function definitions above).
# ==============================================================================
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/cli-parsers.sh" ] && source "${_ARTIFACT_COMMON_DIR}/cli-parsers.sh"
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/runtime-build-fns.sh" ] && source "${_ARTIFACT_COMMON_DIR}/runtime-build-fns.sh"
