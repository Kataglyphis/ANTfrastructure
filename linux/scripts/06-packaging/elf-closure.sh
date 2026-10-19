#!/usr/bin/env bash
# elf-closure.sh: every ELF in a bundle finds its libraries inside it; missing ones go to --lib-dir. See docs/linux-build-basics.md#the-elf-closure-walker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

usage() {
  cat <<'USAGE'
usage: elf-closure.sh --bundle DIR --lib-dir DIR [options]
  --search DIR               look here for a missing library, in the order given
  --from SONAME-GLOB=DIR     such a library comes from DIR or nowhere (the chain ORT, the compiler's libstdc++)
  --ldconfig                 then the ld.so cache
  --ldd                      a file's libraries are what ldd lists for it, transitively, found where the loader finds them
  --system SONAME-GLOB       the target provides it
  --exclude SONAME-GLOB      never bundled: the target's own copy is the one to load (libcamera)
  --no-default-system        drop the built-in glibc and desktop graphics list, for a bundle that carries its C runtime
  --relocatable              a RUNPATH entry outside the bundle resolves nothing: it is dead on the target
  --no-runpath               copy only; the caller sets the RUNPATHs or the loader's --library-path
  --protect GLOB             never patch such a file; its libraries are preloaded instead (preload.list)
  --allow-unresolved SONAME  a library that may stay missing
  --check                    copy and patch nothing; fail on what would be needed
USAGE
}

BUNDLE=""
LIB_DIR=""
CHECK_ONLY=false
USE_LDCONFIG=false
USE_LDD=false
RELOCATABLE=false
RUNPATH=true
DEFAULT_SYSTEM=true
SEARCH=()
FROM=()
PROTECT=()
EXTRA_SYSTEM=()
declare -A ALLOWED_UNRESOLVED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$(realpath -m "${2:?}")"; shift 2 ;;
    --lib-dir) LIB_DIR="$(realpath -m "${2:?}")"; shift 2 ;;
    --search) [ -d "${2:?}" ] && SEARCH+=("$(realpath "$2")"); shift 2 ;;
    --from) FROM+=("${2:?}"); shift 2 ;;
    --ldconfig) USE_LDCONFIG=true; shift ;;
    --ldd) USE_LDD=true; shift ;;
    --allow-unresolved) ALLOWED_UNRESOLVED[${2:?}]=1; shift 2 ;;
    --protect) PROTECT+=("${2:?}"); shift 2 ;;
    --system | --exclude) EXTRA_SYSTEM+=("${2:?}"); shift 2 ;;
    --no-default-system) DEFAULT_SYSTEM=false; shift ;;
    --relocatable) RELOCATABLE=true; shift ;;
    --no-runpath) RUNPATH=false; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -d "${BUNDLE}" ] || err "no bundle at ${BUNDLE}"
[ -n "${LIB_DIR}" ] || err "--lib-dir is required"
for rule in "${FROM[@]}"; do
  case "${rule}" in ?*=?*) ;; *) err "--from needs SONAME-GLOB=DIR: ${rule}" ;; esac
done
mkdir -p "${LIB_DIR}"

SYSTEM_SONAMES=()
# glibc and the desktop graphics stack: what manylinux lets a wheel take from the system.
if [ "${DEFAULT_SYSTEM}" = true ]; then
  SYSTEM_SONAMES=(
    'libc.so.6' 'libm.so.6' 'libpthread.so.0' 'libdl.so.2' 'librt.so.1' 'libresolv.so.2' 'libutil.so.1'
    'libanl.so.1' 'libnsl.so.1' 'ld-linux*.so*'
    'libGL.so.1' 'libEGL.so.1' 'libGLX.so.0' 'libOpenGL.so.0' 'libX11.so.6' 'libXext.so.6' 'libXrender.so.1'
    'libICE.so.6' 'libSM.so.6' 'libglib-2.0.so.0' 'libgobject-2.0.so.0' 'libgthread-2.0.so.0'
  )
fi
# --system and --exclude: what the package's own Depends bring (a distro's GStreamer), or what must stay the target's.
SYSTEM_SONAMES+=("${EXTRA_SYSTEM[@]}")

glob_match() {
  # shellcheck disable=SC2254  # the glob is the point: ld-linux*.so*
  case "$1" in $2) return 0 ;; esac
  return 1
}

is_system() {
  local pattern
  for pattern in "${SYSTEM_SONAMES[@]}"; do
    if glob_match "$1" "${pattern}"; then return 0; fi
  done
  return 1
}

is_elf() {
  if [ "$(head -c 4 -- "$1" 2>/dev/null)" = $'\x7fELF' ]; then return 0; fi
  return 1
}

in_bundle() {
  case "$(realpath -m "$1")/" in "${BUNDLE}"/*) return 0 ;; esac
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
    soname="${soname//\$ORIGIN/${origin}}"
    [ -e "${soname}" ] || return 1
    [ "${RELOCATABLE}" = false ] || in_bundle "${soname}" || return 1
    return 0
  fi
  while IFS= read -r dir; do
    [ -n "${dir}" ] && [ -e "${dir}/${soname}" ] || continue
    if [ "${RELOCATABLE}" = false ] || in_bundle "${dir}"; then return 0; fi
  done < <(runpath_dirs "${file}")
  return 1
}

# deps <file>: "<soname> <path>" per library the file loads; the path is "-" for a NEEDED entry, "?" when ldd found none.
deps() {
  if [ "${USE_LDD}" = false ]; then
    needed "$1" | awk '{ print $1, "-" }'
    return 0
  fi
  ldd "$1" 2>/dev/null | awk '
    $2 == "=>" && $3 ~ /^\// { print $1, $3; next }
    $2 == "=>" && $3 == "not" { print $1, "?"; next }
    $1 ~ /^\// { m = $1; sub(/.*\//, "", m); print m, $1 }' || true
}

# find_source <soname> <ldd path>: the library to copy, from --from, --search, --ldconfig, then where ldd found it.
find_source() {
  local soname="$1" rule dir path=""
  for rule in "${FROM[@]}"; do
    glob_match "${soname}" "${rule%%=*}" || continue
    [ -e "${rule#*=}/${soname}" ] || return 1
    printf '%s' "${rule#*=}/${soname}"
    return 0
  done
  for dir in "${SEARCH[@]}"; do
    if [ -e "${dir}/${soname}" ]; then printf '%s' "${dir}/${soname}"; return 0; fi
  done
  if [ "${USE_LDCONFIG}" = true ]; then
    path="$(ldconfig -p 2>/dev/null | awk -v n="${soname}" '$1 == n { print $NF; exit }' || true)"
  fi
  case "${path}:$2" in :/*) path="$2" ;; esac
  [ -n "${path}" ] && [ -e "${path}" ] || return 1
  printf '%s' "${path}"
}

# A protected file (the chain ORT, which G6 grades byte for byte) is never patched: its libraries are preloaded instead.
is_protected() {
  local rel="${1#"${BUNDLE}"/}" glob
  for glob in "${PROTECT[@]}"; do
    if glob_match "${rel}" "${glob}"; then return 0; fi
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
  local raw
  raw="$(readelf -d "${file}" 2>/dev/null | awk '/\((RUNPATH|RPATH)\)/ { gsub(/[][]/, "", $NF); print $NF }')"
  # Whole entries: a substring test reads $ORIGIN/.. as $ORIGIN, and the needed entry never lands (2026-10-17).
  case ":${raw}:" in *":${token}:"*) return 0 ;; esac
  chmod u+w "${file}"
  patchelf --add-rpath "${token}" "${file}"
}

unresolved=()
copied=()

# already_in_lib_dir <file> <soname>: the library is there; the file still has to reach it.
already_in_lib_dir() {
  local file="$1" soname="$2" rel="${1#"${BUNDLE}"/}"
  [ "${RUNPATH}" = true ] || return 0
  if is_protected "${file}"; then
    if [ "${CHECK_ONLY}" != true ]; then PRELOAD[${soname}]=1; return 0; fi
    grep -qxF -- "${soname}" "${LIB_DIR}/preload.list" 2>/dev/null ||
      unresolved+=("${rel}: ${soname} (protected, and not in preload.list)")
    return 0
  fi
  if [ "${CHECK_ONLY}" = true ]; then
    unresolved+=("${rel}: ${soname} (in the lib dir, but not on its RUNPATH)")
    return 0
  fi
  add_origin_runpath "${file}"
}

# close_needed <file> <soname> <ldd path>: one library is the system's, inside the bundle, copied in, or unresolved.
close_needed() {
  local file="$1" soname="$2" found
  if is_system "${soname}"; then return 0; fi
  case "$3" in
    -) if resolvable "${file}" "${soname}"; then return 0; fi ;;
    /*) if in_bundle "$3"; then return 0; fi ;;
  esac
  if [ -e "${LIB_DIR}/${soname}" ]; then
    already_in_lib_dir "${file}" "${soname}"
    return 0
  fi
  found="$(find_source "${soname}" "$3")" || found=""
  if [ -z "${found}" ] || [ "${CHECK_ONLY}" = true ]; then
    if [ -n "${ALLOWED_UNRESOLVED[${soname}]:-}" ]; then
      warn "  allowed unresolved: ${file#"${BUNDLE}"/} needs ${soname}"
      return 0
    fi
    unresolved+=("${file#"${BUNDLE}"/}: ${soname}")
    return 0
  fi
  cp -L -- "${found}" "${LIB_DIR}/${soname}"
  chmod 0644 "${LIB_DIR}/${soname}"
  copied+=("${soname} <- ${found}")
  queue+=("${LIB_DIR}/${soname}")
  if [ "${RUNPATH}" = true ]; then link_to_lib_dir "${file}" "${soname}"; fi
}

mapfile -t queue < <(find "${BUNDLE}" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print)
declare -A seen=()
while [ "${#queue[@]}" -gt 0 ]; do
  file="${queue[0]}"
  queue=("${queue[@]:1}")
  [ -z "${seen[${file}]:-}" ] || continue
  seen[${file}]=1
  is_elf "${file}" || continue
  while read -r soname path; do
    [ -n "${soname}" ] || continue
    close_needed "${file}" "${soname}" "${path}"
  done < <(deps "${file}")
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
