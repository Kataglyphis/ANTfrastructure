#!/usr/bin/env bash
# Minimal toolchain bootstraps and media builds must strip the same selected ELF files.
[ -n "${_ELF_STRIP_LOADED:-}" ] && return 0
_ELF_STRIP_LOADED=1

strip_elf_files() {
  local jobs="$1" strip_bin="$2"
  shift 2
  [ "$#" -gt 0 ] || return 0
  printf '%s\0' "$@" | xargs -0 -r -P"${jobs}" "${strip_bin}" --strip-all 2>/dev/null || true
}

strip_elf_tree() {
  local dir="$1" jobs strip_bin="${3:-strip}"
  jobs="${2:-$(nproc)}"
  [ -d "${dir}" ] || return 0
  local -a files=()
  mapfile -t files < <(${SUDO:-} find "${dir}" -type f -exec file {} + 2>/dev/null \
    | awk -F': *' '/ELF/{print $1}')
  strip_elf_files "${jobs}" "${strip_bin}" "${files[@]}"
}

# The pattern count separates filename selectors from the caller's batched action argv.
apply_shared_library_action() {
  local source_dir="$1" depth="$2" patterns="$3"
  shift 3
  local -a name_expr=() depth_args=()
  while [ "${patterns}" -gt 0 ]; do
    [ "${#name_expr[@]}" -eq 0 ] || name_expr+=(-o)
    name_expr+=(-name "$1")
    shift
    patterns=$((patterns - 1))
  done
  [ -z "${depth}" ] || depth_args=(-maxdepth "${depth}")
  find "${source_dir}" "${depth_args[@]}" -type f \( "${name_expr[@]}" \) \
    -exec "$@" {} + 2>/dev/null || true
}
