#!/usr/bin/env bash
# Proof workers retain command status while a failed ownership restoration still fails the unit.
migraphx_proof_finish() {
  local status="$1" evidence="$2" core="$3" path
  shift 3
  trap - EXIT
  printf '%s\n' "${status}" > "${evidence}/command-status.txt" || exit "$?"
  source "${core}/bind-mount-ownership.sh" || exit "$?"
  for path; do
    fix_bind_mount_ownership "${path}" "${evidence}" || exit 1
  done
  exit "${status}"
}
