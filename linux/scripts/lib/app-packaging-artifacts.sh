#!/usr/bin/env bash
# A check verifies the build it was handed, never a stale twin; docs/shared-script-libraries.md#app-packaging-artifactssh--one-finished-artifact-per-format
# shellcheck source=linux/scripts/lib/log-bootstrap.sh
source "$(dirname "${BASH_SOURCE[0]}")/log-bootstrap.sh" || return $?

# Usage: app_packaging_single_artifact DIR SUFFIX; prints the one DIR/*SUFFIX regular file.
app_packaging_single_artifact() {
  local dir="${1:?package directory required}" suffix="${2:?artifact suffix required}" path
  local -a found=()
  # The caller's glob options stay untouched; an unmatched pattern, or a missing DIR, is filtered here instead of by nullglob.
  for path in "$dir"/*"$suffix"; do
    if [[ -e "$path" || -L "$path" ]]; then found+=("$path"); fi
  done
  if [[ "${#found[@]}" -eq 1 && -f "${found[0]}" && ! -L "${found[0]}" ]]; then
    printf '%s\n' "${found[0]}"
    return 0
  fi
  printf 'Error: expected exactly one regular *%s file in %s, found %d match(es)\n' "$suffix" "$dir" "${#found[@]}" >&2
  return 1
}

# Usage: app_packaging_linux_artifacts DIR DEB_VAR TARBALL_VAR APPIMAGE_VAR; sets the three variables, or reports every miscount.
app_packaging_linux_artifacts() {
  local _ala_dir="${1:?package directory required}" _ala_deb _ala_tar _ala_appimage _ala_rc=0
  local -n _ala_deb_out="${2:?DEB variable name required}" _ala_tar_out="${3:?tarball variable name required}"
  local -n _ala_appimage_out="${4:?AppImage variable name required}"
  _ala_deb="$(app_packaging_single_artifact "$_ala_dir" .deb)" || _ala_rc=1
  _ala_tar="$(app_packaging_single_artifact "$_ala_dir" .tar.gz)" || _ala_rc=1
  _ala_appimage="$(app_packaging_single_artifact "$_ala_dir" .AppImage)" || _ala_rc=1
  if [[ "$_ala_rc" -ne 0 ]]; then return 1; fi
  _ala_deb_out="$_ala_deb"
  _ala_tar_out="$_ala_tar"
  _ala_appimage_out="$_ala_appimage"
}
