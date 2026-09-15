#!/usr/bin/env bash
# bind-mount-ownership.sh - hand a tree a container wrote back to whoever owns
# the bind mount. A container runs as a different uid than the host user, so a
# docs or packaging step leaves a directory nobody on the host can clean.
#
# The three decisions around the chown -- selective, tolerated as non-root,
# fatal as root -- and why each one is not the obvious alternative:
# docs/shared-script-libraries.md#01-corebind-mount-ownershipsh
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.

[ -n "${_BIND_MOUNT_OWNERSHIP_SH_LOADED:-}" ] && return 0
_BIND_MOUNT_OWNERSHIP_SH_LOADED=1

_BIND_MOUNT_OWNERSHIP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./logging.sh
source "${_BIND_MOUNT_OWNERSHIP_DIR}/logging.sh"

# fix_bind_mount_ownership <target> <reference> -> 0 when the tree is usable.
#
# <reference> is a path the HOST user owns -- normally the workspace root, which
# the mount carries in with the right uid:gid. Its ownership is what <target>
# is handed back to; nothing here takes a uid as an argument, because a number
# typed at a call site is the thing that goes stale.
#
# Returns non-zero ONLY as root, and only when the chown really failed. A
# missing target is not an error: a docs step that produced nothing has nothing
# to hand back.
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
  # -h so a symlink is retargeted rather than its destination, which may be
  # outside the tree the caller asked about.
  if printf '%s\0' "${wrong[@]}" | xargs -0 --no-run-if-empty chown -h "${owner_uid}:${owner_gid}"; then
    return 0
  fi

  if [ "$(id -u)" -ne 0 ]; then
    warn "chown to ${owner_uid}:${owner_gid} is not permitted for uid $(id -u); ${target} stays as it is."
    warn "Only root can hand files to another uid. Run the container as root, or with a uid matching the mount."
    return 0
  fi

  # err() exits 1: as root this is a real error (a read-only or broken mount)
  # and the run must stop, which is what the consumer copy spelled as `die`.
  err "chown -h ${owner_uid}:${owner_gid} under ${target} failed as root; the host user cannot clean or regenerate it."
}
