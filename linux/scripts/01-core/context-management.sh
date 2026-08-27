#!/usr/bin/env bash
# context-management.sh — runtime build context, OCI export, and local stage handoff.
#
# Provides:
#   _export_container_rootfs()
#   export_rootfs_from_image()
#   export_image_to_oci_layout()
#   remove_local_image_if_exists()
#   runtime_pushes_wrapper_images()
#   runtime_pushes_intermediate_images()
#   runtime_use_local_context_chain()
#   runtime_prepare_local_context_chain()
#   runtime_cleanup_local_context_chain()
#   runtime_use_local_stage_context_outputs()
#   runtime_install_local_context_cleanup_trap()
#   runtime_stage_context_dir()
#   runtime_remove_stage_context()
#   runtime_refresh_stage_context()
#   runtime_use_local_artifact_context()
#   runtime_artifact_context_dir()
#   runtime_artifact_context_ref()
#   runtime_stage_export_is_oci()
#   _runtime_resolve_parent_context()
[ -n "${_CONTEXT_MANAGEMENT_SH_LOADED:-}" ] && return 0
_CONTEXT_MANAGEMENT_SH_LOADED=1

_CM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Build helpers (run, nerdctl wrappers) are required.
# Normally sourced by artifact-common.sh first; this is a standalone safety guard.
# shellcheck disable=SC1090,SC1091
if [ -z "${_BUILD_HELPERS_LOADED:-}" ] && [ -f "${_CM_DIR}/build-helpers.sh" ]; then
  source "${_CM_DIR}/build-helpers.sh"
fi

_export_container_rootfs() {
  local nerdctl_bin="$1"
  local tag="$2"
  local rootfs_dir="$3"
  local cid=""

  rm -rf "${rootfs_dir}"
  mkdir -p "${rootfs_dir}"

  cid="$("${nerdctl_bin}" create "${tag}" /bin/true)"

  # NO `trap ... RETURN` here (same leak as the one fixed in parallel-loop.sh):
  # a RETURN trap set inside a function stays armed after an error-path return
  # and fires again when the CALLER returns — where ${cid} is not in scope, so
  # under `set -u` the second firing aborts the caller instead of cleaning up.
  # Capturing the rc with `|| rc=$?` keeps set -e from returning early, so the
  # explicit cleanup below runs on both the happy and the failure path.
  local rc=0
  "${nerdctl_bin}" export "${cid}" | tar -xpf - -C "${rootfs_dir}" || rc=$?

  "${nerdctl_bin}" rm -f "${cid}" >/dev/null 2>&1 || true
  return "${rc}"
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

# Reclaim stage-context trees left behind by runs that never got to clean up.
#
# runtime_cleanup_local_context_chain only removes the workdir THIS process
# mktemp'd, so anything killed hard -- SIGKILL, an OOM, or the chain's own
# `chain_terminate_descendants ... KILL` -- leaks its entire tree. Found
# 2026-08-27 on the dev host: runtime-flow.c3d3B6, dated 2026-07-25, holding a
# full base-amd64 rootfs at 3.3 GB, survived 33 days and every disk guard on a
# filesystem sitting at 93% used. A leak can be far larger than that: the
# runtime stage holds a base rootfs plus a package OCI layout PER ARCH, which
# build-cross-chain.sh itself budgets at ~30 GB.
#
# Deliberately age-based rather than "delete every sibling": a concurrent
# second chain has a young workdir of its own and must not be robbed. Anything
# older than RUNTIME_CONTEXT_KEEP_HOURS cannot belong to a live run, because a
# run that lived that long would have refreshed its contexts.
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
