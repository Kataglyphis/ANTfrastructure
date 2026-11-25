#!/usr/bin/env bash
# Moves executables beside the loader and glibc they were linked against and leaves launchers in their place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../01-core/logging.sh
source "${SCRIPT_DIR}/../01-core/logging.sh"

# --beside keeps the executable's directory (as <name>.bin): /proc/self/exe names the loader, and Flutter finds data/ there.
BESIDE=false
EXTERNAL_LIBRARY_PATH=false
PRESERVE_BYTES=false
GCC_UNWINDER=false
while :; do
  case "${1:-}" in
    --beside) BESIDE=true; shift ;;
    --external-library-path) EXTERNAL_LIBRARY_PATH=true; shift ;;
    --preserve-bytes) PRESERVE_BYTES=true; shift ;;
    --gcc-unwinder) GCC_UNWINDER=true; shift ;;
    *) break ;;
  esac
done
if [ $# -lt 3 ]; then
  printf 'usage: %s [--beside] [--external-library-path] [--preserve-bytes] [--gcc-unwinder] BUNDLE LIB-DIR EXECUTABLE...\n' "$0" >&2
  exit 2
fi
BUNDLE="$(realpath -m "$1")"
LIB_DIR="$(realpath -m "$2")"
shift 2
EXES=("$@")
[ -d "${BUNDLE}" ] || err "no bundle at ${BUNDLE}"
if [ "${PRESERVE_BYTES}" = true ]; then
  [[ "${LIB_DIR}" == "${BUNDLE}/"* ]] || err "immutable helper libraries must stay inside the bundle"
fi
mkdir -p "${LIB_DIR}"
# A Flutter engine exports its own _Unwind_*, which cannot catch ROCm's internal C++ exceptions: docs/failure-modes.md
if [ "${GCC_UNWINDER}" = true ]; then
  [ -f "${LIB_DIR}/libgcc_s.so.1" ] && [ ! -L "${LIB_DIR}/libgcc_s.so.1" ] || err "--gcc-unwinder needs a regular ${LIB_DIR}/libgcc_s.so.1"
fi

# glibc's own libraries; python-app-closure.sh leaves all of them to the system, so they come from here.
GLIBC_SONAMES=(libc.so.6 libm.so.6 libmvec.so.1 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2
  libutil.so.1 libanl.so.1 libnss_files.so.2 libnss_dns.so.2)

interpreter() { readelf -l "$1" | sed -n 's/.*Requesting program interpreter: \(.*\)]$/\1/p'; }
glibc_version() { "$1" --version 2>/dev/null | sed -n '1s/.*release version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p'; }

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
    if [ "${EXTERNAL_LIBRARY_PATH}" = true ] && ! grep -q '^external_library_path=' "${exe}"; then
      err "${rel} is already a launcher without external library paths; restage the executable"
    fi
    preserved=false
    grep -q '^# Original executable bytes must survive package hash checks\.$' "${exe}" && preserved=true
    [ "${PRESERVE_BYTES}" = "${preserved}" ] || err "${rel} has a different byte-preservation policy; restage the executable"
    unwinder=false
    grep -q '^# The bundled libgcc_s unwinder is preloaded\.$' "${exe}" && unwinder=true
    [ "${GCC_UNWINDER}" = "${unwinder}" ] || err "${rel} has a different unwinder policy; restage the executable"
    info "  ${rel}: already a launcher"
    continue
  fi
  original_hash=""
  if [ "${PRESERVE_BYTES}" = true ]; then
    resolved="$(realpath -e -- "${exe}")"
    [ -x "${exe}" ] && [ ! -L "${exe}" ] && [[ "${resolved}" == "${BUNDLE}/"* ]] || err "${rel} is not a regular executable inside the bundle"
    dynamic="$(readelf -d "${exe}")"
    if grep -q '(RPATH)' <<< "${dynamic}"; then err "${rel} has legacy RPATH which precedes the private library path"; fi
    original_hash="$(sha256sum < "${exe}")"
  fi
  interp="$(interpreter "${exe}")"
  [ -n "${interp}" ] || err "${rel} names no program interpreter"
  loader="$(basename "${interp}")"
  glibc_dir="$(dirname "$(realpath "${interp}")")"
  exe_dir="$(dirname "${exe}")"
  to_lib="$(realpath -m --relative-to="${exe_dir}" "${LIB_DIR}")"
  if [ "${BESIDE}" = true ]; then home="${exe_dir}"; to_home="."; else home="${LIB_DIR}"; to_home="${to_lib}"; fi
  name="$(basename "${exe}")"
  real="${name}"
  [ "${PRESERVE_BYTES}" = true ] && real="${name}-bin"
  [ "${BESIDE}" = true ] && real="${name}.bin"
  if [ "${PRESERVE_BYTES}" = true ]; then
    [ ! -e "${home}/${real}" ] && [ ! -L "${home}/${real}" ] || err "payload already exists at ${home}/${real}"
  fi
  read -r major minor <<< "$(glibc_version "${interp}")"
  [ -n "${minor:-}" ] || err "cannot read the glibc version of ${interp}"
  [ -e "${home}/${loader}" ] || cp -L "${interp}" "${home}/${loader}"
  # Apart from lib/: a host loader that took them through a RUNPATH would mix two glibcs.
  mkdir -p "${LIB_DIR}/glibc"
  for soname in "${GLIBC_SONAMES[@]}"; do
    [ -e "${glibc_dir}/${soname}" ] && [ ! -e "${LIB_DIR}/glibc/${soname}" ] && cp -L "${glibc_dir}/${soname}" "${LIB_DIR}/glibc/${soname}"
  done

  mv "${exe}" "${home}/${real}"
  byte_policy=""
  if [ "${PRESERVE_BYTES}" = true ]; then
    [ "$(sha256sum < "${home}/${real}")" = "${original_hash}" ] || err "${rel}: original executable bytes changed"
    byte_policy=$'\n# Original executable bytes must survive package hash checks.'
  else
    move_runpath "${exe_dir}" "${home}/${real}"
  fi
  external_setup=""
  external_suffix=""
  host_preload=""
  bundled_preload=""
  if [ "${GCC_UNWINDER}" = true ]; then
    byte_policy="${byte_policy}"$'\n# The bundled libgcc_s unwinder is preloaded.'
    host_preload="$(printf '\n  export LD_PRELOAD="$here/%s/libgcc_s.so.1${LD_PRELOAD:+:$LD_PRELOAD}"' "${to_lib}")"
    bundled_preload=" --preload \"\$here/${to_lib}/libgcc_s.so.1\""
  fi
  if [ "${EXTERNAL_LIBRARY_PATH}" = true ]; then
    external_setup="$(cat <<EXTERNAL

external_library_path=""
IFS=: read -r -a external_library_dirs <<< "\${LD_LIBRARY_PATH:-}"
for external_library_dir in "\${external_library_dirs[@]}"; do
  [ -z "\${external_library_dir}" ] || external_library_path="\${external_library_path}:\${external_library_dir}"
done
export LD_LIBRARY_PATH="\$here/${to_lib}\${external_library_path}"
EXTERNAL
)"
    external_suffix="\${external_library_path}"
  elif [ "${PRESERVE_BYTES}" = true ]; then
    external_setup="$(printf '\nexport LD_LIBRARY_PATH="$here/%s"' "${to_lib}")"
  fi
  # The host's own glibc when it is new enough: its GL drivers need it (a flatpak runtime's 2.44 under a 2.43 bundle).
  cat > "${exe}" <<LAUNCHER
#!/bin/bash
# Starts ${name} with the host's glibc when it is ${major}.${minor} or newer, else with the bundled loader and glibc.${byte_policy}
here="\$(cd -- "\$(dirname -- "\$(readlink -f -- "\$0")")" && pwd)"${external_setup}
# Not read < <(...): that child would outlive the exec below as a stray child of the program (Python's forkserver warns).
host_glibc="\$("${interp}" --version 2>/dev/null | sed -n '1s/.*release version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
read -r host_major host_minor <<< "\$host_glibc"
if [ -z "\${KATAGLYPHIS_BUNDLED_GLIBC:-}" ] && [ -n "\${host_minor:-}" ] &&
  { [ "\$host_major" -gt ${major} ] || { [ "\$host_major" -eq ${major} ] && [ "\$host_minor" -ge ${minor} ]; }; }; then${host_preload}
  exec -a "\$0" "\$here/${to_home}/${real}" "\$@"
fi
exec "\$here/${to_home}/${loader}" --library-path "\$here/${to_lib}/glibc:\$here/${to_lib}${external_suffix}"${bundled_preload} --argv0 "\$0" "\$here/${to_home}/${real}" "\$@"
LAUNCHER
  chmod 0755 "${exe}"
  info "  ${rel}: launcher -> ${to_home}/${real}, through ${loader} and glibc ${major}.${minor} (${glibc_dir}) on an older host"
done
