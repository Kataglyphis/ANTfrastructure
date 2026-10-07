#!/usr/bin/env bash
# Runtime build contexts, OCI export and the local stage handoff.
[ -n "${_CONTEXT_MANAGEMENT_SH_LOADED:-}" ] && return 0
_CONTEXT_MANAGEMENT_SH_LOADED=1

_CM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# For a standalone source; artifact-common.sh normally loads it first.
# shellcheck disable=SC1090,SC1091
if [ -z "${_BUILD_HELPERS_LOADED:-}" ] && [ -f "${_CM_DIR}/build-helpers.sh" ]; then
  source "${_CM_DIR}/build-helpers.sh"
fi

# <nerdctl> <tag> <cmd...>: runs "<cmd...> <cid>", always removes the container; no RETURN trap, it re-fires in the caller.
_with_throwaway_container() {
  local nerdctl_bin="$1" tag="$2" cid rc=0
  shift 2
  cid="$("${nerdctl_bin}" create "${tag}" /bin/true)" || return 1
  "$@" "${cid}" || rc=$?
  "${nerdctl_bin}" rm -f "${cid}" >/dev/null 2>&1 || true
  return "${rc}"
}

# <nerdctl> <rootfs_dir> <cid>
_export_cid_rootfs() {
  "$1" export "$3" | tar -xpf - -C "$2"
}

_export_container_rootfs() {
  local nerdctl_bin="$1"
  local tag="$2"
  local rootfs_dir="$3"

  rm -rf "${rootfs_dir}"
  mkdir -p "${rootfs_dir}"
  _with_throwaway_container "${nerdctl_bin}" "${tag}" \
    _export_cid_rootfs "${nerdctl_bin}" "${rootfs_dir}"
}

export_rootfs_from_image() {
  local nerdctl_bin="$1"
  local tag="$2"
  local artifact_dir="$3"
  shift 3

  local rootfs_dir="${artifact_dir}/rootfs"
  _export_container_rootfs "${nerdctl_bin}" "${tag}" "${rootfs_dir}" || return 1

  if [ "$#" -gt 0 ]; then
    : > "${artifact_dir}/artifact.env"
    while [ "$#" -gt 0 ]; do
      printf '%s\n' "$1" >> "${artifact_dir}/artifact.env"
      shift
    done
  fi
  # Explicit: the trailing `if` test would otherwise BE the exit status.
  return 0
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

runtime_pushes_wrapper_images() {
  _bool_truthy "${PUSH_IMAGES:-0}"
}

runtime_pushes_intermediate_images() {
  runtime_pushes_wrapper_images && _bool_truthy "${PUSH_INTERMEDIATE_IMAGES:-0}"
}

runtime_use_local_context_chain() {
  case "${RUNTIME_USE_LOCAL_CONTEXT_CHAIN:-auto}" in
    auto|"") ! runtime_pushes_intermediate_images ;;
    *) _bool_truthy "${RUNTIME_USE_LOCAL_CONTEXT_CHAIN:-false}" ;;
  esac
}

runtime_prepare_local_context_chain() {
  runtime_use_local_context_chain || return 0
  if [ -n "${RUNTIME_CONTEXT_WORKDIR:-}" ]; then
    return 0
  fi
  mkdir -p "${RUNTIME_CONTEXT_ROOT}"
  _runtime_sweep_orphaned_contexts
  RUNTIME_CONTEXT_WORKDIR="$(mktemp -d "${RUNTIME_CONTEXT_ROOT}/runtime-flow.XXXXXX")"
}

# A hard-killed run leaks its whole workdir; age-based so a concurrent chain's young workdir survives.
_runtime_sweep_orphaned_contexts() {
  local keep_hours="${RUNTIME_CONTEXT_KEEP_HOURS:-24}"
  local d freed=0
  [ -d "${RUNTIME_CONTEXT_ROOT}" ] || return 0
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    [ "${d}" = "${RUNTIME_CONTEXT_WORKDIR:-}" ] && continue
    log "[context] reclaiming orphaned stage-context $(basename "${d}") ($(du -sh "${d}" 2>/dev/null | cut -f1 || true), older than ${keep_hours}h)"
    rm -rf "${d}" && freed=$((freed + 1))
  done < <(find "${RUNTIME_CONTEXT_ROOT}" -mindepth 1 -maxdepth 1 -type d \
             -name 'runtime-flow.*' -mmin "+$((keep_hours * 60))" 2>/dev/null || true)
  [ "${freed}" -eq 0 ] || log "[context] reclaimed ${freed} orphaned stage-context tree(s)"
}

runtime_cleanup_local_context_chain() {
  if [ -n "${RUNTIME_CONTEXT_WORKDIR:-}" ] && [ -d "${RUNTIME_CONTEXT_WORKDIR}" ]; then
    rm -rf "${RUNTIME_CONTEXT_WORKDIR}"
  fi
  RUNTIME_CONTEXT_WORKDIR=""
}

runtime_use_local_stage_context_outputs() {
  runtime_use_local_context_chain || return 1
  ! runtime_pushes_intermediate_images
}

runtime_install_local_context_cleanup_trap() {
  trap_push 'runtime_cleanup_local_context_chain'
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
  _export_container_rootfs "${NERDCTL_BIN:-nerdctl}" "${image_ref}" "${context_dir}"
}

# A directory, not a second OCI context: docs/failure-modes.md#a-no-push-wrapper-build-cannot-find-its-own-android-image
_export_cid_wheels() {
  "$1" export "$3" | tar -xpf - -C "$2" opt/wheels opt/wheels-cp314t
}

runtime_wheels_context_dir() {
  local arch="$1" image_ref="$2" dir
  local nerdctl_bin="${NERDCTL_BIN:-nerdctl}"
  dir="$(runtime_stage_context_dir wheels "${arch}")" || return 1
  rm -rf "${dir}"
  mkdir -p "${dir}"
  _with_throwaway_container "${nerdctl_bin}" "${image_ref}" \
    _export_cid_wheels "${nerdctl_bin}" "${dir}" || return 1
  printf '%s' "${dir}"
}

runtime_use_local_artifact_context() {
  [ -n "${ARTIFACT_CONTEXT_ROOT:-}" ]
}

# `<root>-<arch>`, exactly what cross_stage_context_dir writes; a slash made --no-push fall back to a stale tag.
runtime_artifact_context_dir() {
  local arch="$1"
  if [ -z "${ARTIFACT_CONTEXT_ROOT:-}" ]; then
    printf '[ERROR] ARTIFACT_CONTEXT_ROOT is required for local artifact contexts\n' >&2
    return 1
  fi
  printf '%s' "${ARTIFACT_CONTEXT_ROOT%/}-${arch}"
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

# <kind> <arch> <image_ref> <context_dir> <build_args>: a remote tag, or a local context plus its --build-context arg.
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
