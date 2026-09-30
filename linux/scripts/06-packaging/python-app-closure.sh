#!/usr/bin/env bash
# Makes every ELF in a bundle find its libraries inside it: missing ones go to --lib-dir, users get an $ORIGIN RUNPATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

BUNDLE=""
LIB_DIR=""
CHECK_ONLY=false
SEARCH=()
PROTECT=()
declare -A ALLOWED_UNRESOLVED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$(realpath -m "${2:?}")"; shift 2 ;;
    --lib-dir) LIB_DIR="$(realpath -m "${2:?}")"; shift 2 ;;
    --search) [ -d "${2:?}" ] && SEARCH+=("$(realpath "$2")"); shift 2 ;;
    --allow-unresolved) ALLOWED_UNRESOLVED[${2:?}]=1; shift 2 ;;
    --protect) PROTECT+=("${2:?}"); shift 2 ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help) printf 'usage: %s --bundle DIR --lib-dir DIR [--search DIR]... [--allow-unresolved SONAME]... [--protect GLOB]... [--check]\n' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -d "${BUNDLE}" ] || err "no bundle at ${BUNDLE}"
[ -n "${LIB_DIR}" ] || err "--lib-dir is required"
mkdir -p "${LIB_DIR}"

# glibc and the desktop graphics stack: what manylinux lets a wheel take from the system.
SYSTEM_SONAMES=(
  'libc.so.6' 'libm.so.6' 'libpthread.so.0' 'libdl.so.2' 'librt.so.1' 'libresolv.so.2' 'libutil.so.1'
  'libanl.so.1' 'libnsl.so.1' 'ld-linux*.so*'
  'libGL.so.1' 'libEGL.so.1' 'libGLX.so.0' 'libOpenGL.so.0' 'libX11.so.6' 'libXext.so.6' 'libXrender.so.1'
  'libICE.so.6' 'libSM.so.6' 'libglib-2.0.so.0' 'libgobject-2.0.so.0' 'libgthread-2.0.so.0'
)

is_system() {
  local pattern
  for pattern in "${SYSTEM_SONAMES[@]}"; do
    # shellcheck disable=SC2254  # the glob is the point: ld-linux*.so*
    case "$1" in ${pattern}) return 0 ;; esac
  done
  return 1
}

is_elf() {
  if [ "$(head -c 4 -- "$1" 2>/dev/null)" = $'\x7fELF' ]; then return 0; fi
  return 1
}

needed() { readelf -d "$1" 2>/dev/null | awk '/\(NEEDED\)/ { gsub(/[][]/, "", $NF); print $NF }'; }

runpath_dirs() {
  local file="$1" origin raw dir
  origin="$(dirname "$(realpath "${file}")")"
  raw="$(readelf -d "${file}" 2>/dev/null | awk '/\((RUNPATH|RPATH)\)/ { gsub(/[][]/, "", $NF); print $NF }')"
  local -a dirs=()
  IFS=':' read -r -a dirs <<< "${raw}"
  for dir in "${dirs[@]}"; do
    dir="${dir//\$\{ORIGIN\}/${origin}}"
    printf '%s\n' "${dir//\$ORIGIN/${origin}}"
  done
}

resolvable() {
  local file="$1" soname="$2" dir origin
  # A NEEDED entry with a slash is a path; glibc expands $ORIGIN in it (python-build-standalone's libpython3.so).
  if [[ "${soname}" == */* ]]; then
    origin="$(dirname "$(realpath "${file}")")"
    soname="${soname//\$\{ORIGIN\}/${origin}}"
    [ -e "${soname//\$ORIGIN/${origin}}" ]
    return
  fi
  while IFS= read -r dir; do
    [ -n "${dir}" ] && [ -e "${dir}/${soname}" ] && return 0
  done < <(runpath_dirs "${file}")
  return 1
}

# A protected file (the chain ORT, which G6 grades byte for byte) is never patched: its libraries are preloaded instead.
is_protected() {
  local rel="${1#"${BUNDLE}"/}" glob
  for glob in "${PROTECT[@]}"; do
    # shellcheck disable=SC2053  # the glob is the point
    [[ "${rel}" == ${glob} ]] && return 0
  done
  return 1
}

declare -A PRELOAD=()

# The lib dir is not on a protected file's RUNPATH; sitecustomize.py loads the library first, and the soname then matches.
link_to_lib_dir() {
  local file="$1" soname="$2"
  if is_protected "${file}"; then PRELOAD[${soname}]=1; return 0; fi
  add_origin_runpath "${file}"
}

add_origin_runpath() {
  local file="$1" rel token
  rel="$(realpath --relative-to="$(dirname "$(realpath "${file}")")" "${LIB_DIR}")"
  token='$ORIGIN'
  [ "${rel}" = "." ] || token="\$ORIGIN/${rel}"
  readelf -d "${file}" 2>/dev/null | grep -qF -- "${token}" && return 0
  chmod u+w "${file}"
  patchelf --add-rpath "${token}" "${file}"
}

mapfile -t queue < <(find "${BUNDLE}" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print)
declare -A seen=()
unresolved=()
copied=()
while [ "${#queue[@]}" -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")
  [ -z "${seen[${file}]:-}" ] || continue
  seen[${file}]=1
  is_elf "${file}" || continue
  while IFS= read -r soname; do
    [ -n "${soname}" ] || continue
    if is_system "${soname}" || resolvable "${file}" "${soname}"; then continue; fi
    if [ -e "${LIB_DIR}/${soname}" ]; then
      if is_protected "${file}"; then
        if [ "${CHECK_ONLY}" = true ]; then
          grep -qxF -- "${soname}" "${LIB_DIR}/preload.list" 2>/dev/null ||
            unresolved+=("${file#"${BUNDLE}"/}: ${soname} (protected, and not in preload.list)")
        else
          PRELOAD[${soname}]=1
        fi
        continue
      fi
      [ "${CHECK_ONLY}" = true ] && { unresolved+=("${file#"${BUNDLE}"/}: ${soname} (in the lib dir, but not on its RUNPATH)"); continue; }
      add_origin_runpath "${file}"
      continue
    fi
    found=""
    for dir in "${SEARCH[@]}"; do
      if [ -e "${dir}/${soname}" ]; then found="${dir}/${soname}"; break; fi
    done
    if [ -z "${found}" ] || [ "${CHECK_ONLY}" = true ]; then
      if [ -n "${ALLOWED_UNRESOLVED[${soname}]:-}" ]; then
        warn "  allowed unresolved: ${file#"${BUNDLE}"/} needs ${soname}"
        continue
      fi
      unresolved+=("${file#"${BUNDLE}"/}: ${soname}")
      continue
    fi
    cp -L -- "${found}" "${LIB_DIR}/${soname}"
    chmod 0644 "${LIB_DIR}/${soname}"
    copied+=("${soname} <- ${found}")
    queue+=("${LIB_DIR}/${soname}")
    link_to_lib_dir "${file}" "${soname}"
  done < <(needed "${file}")
done

if [ "${CHECK_ONLY}" != true ] && [ "${#PRELOAD[@]}" -gt 0 ]; then
  printf '%s\n' "${!PRELOAD[@]}" | sort > "${LIB_DIR}/preload.list"
  info "  preload.list: $(tr '\n' ' ' < "${LIB_DIR}/preload.list")"
fi
for line in "${copied[@]}"; do info "  copied ${line}"; done
if [ "${#unresolved[@]}" -gt 0 ]; then
  printf 'ERROR: %d library reference(s) resolve neither inside the bundle nor to the system allowlist:\n' "${#unresolved[@]}" >&2
  printf '  %s\n' "${unresolved[@]}" >&2
  exit 1
fi
info "ELF closure: every NEEDED resolves inside ${BUNDLE} or to the system allowlist (${#copied[@]} copied)"
