#!/usr/bin/env bash
# Moves executables beside the loader and glibc they were linked against and leaves launchers in their place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

# --beside keeps the executable's directory (as <name>.bin): /proc/self/exe names the loader, and Flutter finds data/ there.
BESIDE=false
if [ "${1:-}" = --beside ]; then BESIDE=true; shift; fi
if [ $# -lt 3 ]; then
  printf 'usage: %s [--beside] BUNDLE LIB-DIR EXECUTABLE...  (each executable relative to BUNDLE)\n' "$0" >&2
  exit 2
fi
BUNDLE="$(realpath -m "$1")"
LIB_DIR="$(realpath -m "$2")"
shift 2
EXES=("$@")
[ -d "${BUNDLE}" ] || err "no bundle at ${BUNDLE}"
mkdir -p "${LIB_DIR}"

# glibc's own libraries; python-app-closure.sh leaves all of them to the system, so they come from here.
GLIBC_SONAMES=(libc.so.6 libm.so.6 libmvec.so.1 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2
  libutil.so.1 libanl.so.1 libnss_files.so.2 libnss_dns.so.2)

interpreter() { readelf -l "$1" | sed -n 's/.*Requesting program interpreter: \(.*\)]$/\1/p'; }

# Each RUNPATH entry keeps pointing at the same directory after the file moves from $1 to $2.
move_runpath() {
  local from_dir="$1" file="$2" raw entry target out=""
  raw="$(readelf -d "${file}" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"
  [ -n "${raw}" ] || return 0
  local -a entries=()
  IFS=':' read -r -a entries <<< "${raw}"
  for entry in "${entries[@]}"; do
    case "${entry}" in
      '$ORIGIN'*) target="$(realpath -m "${from_dir}/${entry#\$ORIGIN}")"
        entry="\$ORIGIN/$(realpath -m --relative-to="$(dirname "${file}")" "${target}")" ;;
    esac
    out="${out:+${out}:}${entry%/.}"
  done
  patchelf --set-rpath "${out}" "${file}"
}

for rel in "${EXES[@]}"; do
  exe="${BUNDLE}/${rel}"
  [ -f "${exe}" ] || err "no executable at ${exe}"
  # A second run finds the launcher it wrote: the program already sits beside its loader.
  if [ "$(head -c 2 -- "${exe}")" = '#!' ] && grep -q -- '--library-path' "${exe}"; then
    info "  ${rel}: already a launcher"
    continue
  fi
  interp="$(interpreter "${exe}")"
  [ -n "${interp}" ] || err "${rel} names no program interpreter"
  loader="$(basename "${interp}")"
  glibc_dir="$(dirname "$(realpath "${interp}")")"
  exe_dir="$(dirname "${exe}")"
  to_lib="$(realpath -m --relative-to="${exe_dir}" "${LIB_DIR}")"
  if [ "${BESIDE}" = true ]; then home="${exe_dir}"; to_home="."; else home="${LIB_DIR}"; to_home="${to_lib}"; fi
  [ -e "${home}/${loader}" ] || cp -L "${interp}" "${home}/${loader}"
  for soname in "${GLIBC_SONAMES[@]}"; do
    [ -e "${glibc_dir}/${soname}" ] && [ ! -e "${LIB_DIR}/${soname}" ] && cp -L "${glibc_dir}/${soname}" "${LIB_DIR}/${soname}"
  done

  name="$(basename "${exe}")"
  real="${name}"
  [ "${BESIDE}" = true ] && real="${name}.bin"
  mv "${exe}" "${home}/${real}"
  move_runpath "${exe_dir}" "${home}/${real}"
  cat > "${exe}" <<LAUNCHER
#!/bin/sh
# Starts ${name} with the loader and C library it was built against, whatever glibc the host has.
here="\$(cd -- "\$(dirname -- "\$(readlink -f -- "\$0")")" && pwd)"
exec "\$here/${to_home}/${loader}" --library-path "\$here/${to_lib}" --argv0 "\$0" "\$here/${to_home}/${real}" "\$@"
LAUNCHER
  chmod 0755 "${exe}"
  info "  ${rel}: launcher -> ${to_home}/${real} through ${loader} (glibc from ${glibc_dir})"
done
