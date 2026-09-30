#!/usr/bin/env bash
# Hands a container-written tree back to the bind mount's owner: docs/shared-script-libraries.md#01-corebind-mount-ownershipsh

[ -n "${_BIND_MOUNT_OWNERSHIP_SH_LOADED:-}" ] && return 0
_BIND_MOUNT_OWNERSHIP_SH_LOADED=1

_BIND_MOUNT_OWNERSHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./logging.sh
source "${_BIND_MOUNT_OWNERSHIP_DIR}/logging.sh"

# fix_bind_mount_ownership <target> <host-owned reference>: fails only as root when the chown fails; no uid argument to go stale.
fix_bind_mount_ownership() {
  local target="${1:?fix_bind_mount_ownership: target directory required}"
  local reference="${2:?fix_bind_mount_ownership: reference path required}"

  if [ ! -d "${target}" ]; then
    info "Nothing to fix: ${target} does not exist"
    return 0
  fi
  if [ ! -e "${reference}" ]; then
    err "fix_bind_mount_ownership: reference path does not exist: ${reference}"
  fi

  local owner_uid owner_gid
  owner_uid="$(stat -c "%u" "${reference}")"
  owner_gid="$(stat -c "%g" "${reference}")"

  # Only the paths that actually differ, never a blanket `chown -R`.
  local -a wrong=()
  mapfile -d '' -t wrong < <(
    find "${target}" \( ! -uid "${owner_uid}" -o ! -gid "${owner_gid}" \) -print0 2>/dev/null
  )

  if [ "${#wrong[@]}" -eq 0 ]; then
    info "${target} is already owned by ${owner_uid}:${owner_gid}; nothing to do"
    return 0
  fi

  info "Handing ${#wrong[@]} path(s) under ${target} back to ${owner_uid}:${owner_gid}"
  # -h: a symlink's destination may lie outside the tree.
  if printf '%s\0' "${wrong[@]}" | xargs -0 --no-run-if-empty chown -h "${owner_uid}:${owner_gid}"; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    warn "chown to ${owner_uid}:${owner_gid} is not permitted for uid $(id -u); ${target} stays as it is."
    warn "Only root can hand files to another uid. Run the container as root, or with a uid matching the mount."
    return 0
  fi

  # As root a failed chown means a broken or read-only mount, so err() stops the run.
  err "chown -h ${owner_uid}:${owner_gid} under ${target} failed as root; the host user cannot clean or regenerate it."
}
