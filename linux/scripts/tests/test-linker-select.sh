#!/usr/bin/env bash
# lib/linker-select.sh against stub cc/rustc/uname and a stubbed download; see docs/shared-script-libraries.md#linker-selectsh--an-opt-in-linker
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="$(cd "${TESTS_DIR}/.." && pwd)/lib/linker-select.sh"
VERSIONS="$(cd "${TESTS_DIR}/.." && pwd)/01-core/versions.env"

_WORK="$(mktemp -d)"
trap 'rm -rf "${_WORK}"' EXIT

# Stubs go in front of the system dirs only; copied or linked tools do not run outside /usr/bin under MSYS.
SYS=/usr/bin:/bin
mkdir -p "${_WORK}/bin" "${_WORK}/norust" "${_WORK}/badcc" "${_WORK}/llvm/bin" "${_WORK}/llvm/lib" "${_WORK}/moldbin"
_stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1"; chmod +x "$1"; }
# cc records its arguments and writes the -o file; badcc/cc is a driver that cannot link.
_CC='cat >/dev/null; printf "%s\n" "$*" >> "'"${_WORK}"'/cc.log"
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && : > "$2"; shift; done; exit 0'
_stub "${_WORK}/bin/cc" "${_CC}"
_stub "${_WORK}/norust/cc" "${_CC}"
_stub "${_WORK}/llvm/bin/clang" "${_CC}"
_stub "${_WORK}/badcc/cc" 'cat >/dev/null; exit 1'
: > "${_WORK}/llvm/lib/LLVMgold.so"
_stub "${_WORK}/bin/rustc" 'printf "rustc 1.98.1\nhost: x86_64-unknown-linux-gnu\n"'
# A rustc that names no host stands in for none at all, whatever the system dirs carry.
_stub "${_WORK}/norust/rustc" 'exit 1'
_stub "${_WORK}/bin/uname" 'printf "%s\n" "${STUB_UNAME_M:-x86_64}"'
_stub "${_WORK}/norust/uname" 'printf "%s\n" "${STUB_UNAME_M:-x86_64}"'
_stub "${_WORK}/moldbin/ld.mold" 'exit 0'

# _sel <strict,twice,show|-> <PATH> [VAR=value...]: prints rc|LDFLAGS|cargo linker|cargo rustflags[|ld.mold]; the download is a stub.
_sel() {
  local flags="$1" path="$2"; shift 2
  env -i HOME="${_WORK}" TMPDIR="${_WORK}" PATH="${path}" "$@" bash -c '
    flags=" ${1//,/ } "
    [[ "${flags}" == *" strict "* ]] && set -euo pipefail
    source "'"${LIB}"'"
    # After the source, which loads the real downloads.sh.
    download_verified_file() {
      printf "%s\n" "$2" >> "'"${_WORK}"'/download.log"
      local asset; asset="$(basename "$3" .tar.gz)"
      local stage; stage="$(mktemp -d)"
      mkdir -p "${stage}/${asset}/bin"
      printf "#!/usr/bin/env bash\nexit 0\n" > "${stage}/${asset}/bin/ld.mold"
      chmod +x "${stage}/${asset}/bin/ld.mold"
      tar -czf "$3" -C "${stage}" "${asset}"
    }
    linker_select_env >/dev/null; rc=$?
    [[ "${flags}" == *" twice "* ]] && { linker_select_env >/dev/null || rc=$?; }
    v=CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU
    l="${v}_LINKER"; r="${v}_RUSTFLAGS"
    printf "%s|%s|%s|%s" "${rc}" "${LDFLAGS:-}" "${!l:-}" "${!r:-}"
    [[ "${flags}" == *" show "* ]] && printf "|%s" "$(command -v ld.mold)"
  ' _ "${flags}" 2>/dev/null
}
P="${_WORK}/bin:${SYS}"

t_case "unset and default leave the environment alone"
t_assert_eq "0|||" "$(_sel - "${P}")"
t_assert_eq "0|-Wl,-O1||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=default LDFLAGS=-Wl,-O1)"

t_case "an unknown linker is refused with 2"
t_assert_eq "2|||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=gold)"

t_case "lld: LDFLAGS appended, the host Rust target linked through cc with the same linker"
t_assert_eq "0|-Wl,-O1 -fuse-ld=lld|cc|-C link-arg=-fuse-ld=lld" \
  "$(_sel - "${P}" KATAGLYPHIS_LINKER=lld LDFLAGS=-Wl,-O1)"
t_assert_eq "0|-fuse-ld=lld|cc|-C target-cpu=native -C link-arg=-fuse-ld=lld" \
  "$(_sel - "${P}" KATAGLYPHIS_LINKER=lld CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS='-C target-cpu=native')"

t_case "a second call, or a child process that inherits the first, appends nothing"
t_assert_eq "0|-fuse-ld=lld|cc|-C link-arg=-fuse-ld=lld" "$(_sel twice "${P}" KATAGLYPHIS_LINKER=lld)"
t_assert_eq "0|-fuse-ld=lld||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=lld _LINKER_SELECT_APPLIED=lld LDFLAGS=-fuse-ld=lld)"

t_case "under set -euo pipefail, as the cargo wrappers source it"
t_assert_eq "0|-fuse-ld=lld|cc|-C link-arg=-fuse-ld=lld" "$(_sel strict "${P}" KATAGLYPHIS_LINKER=lld)"

t_case "cmake_build_prepare_env applies it, so every cmake-build.sh consumer has the switch"
t_assert_eq "-fuse-ld=lld" "$(env -i HOME="${_WORK}" TMPDIR="${_WORK}" PATH="${P}" KATAGLYPHIS_LINKER=lld \
  CMAKE_BUILD_SAFE_DIRECTORY='' bash -c 'source "'"${LIB%/*}"'/cmake-build.sh"
    cmake_build_prepare_env >/dev/null 2>&1; printf "%s" "${LDFLAGS:-}"' 2>/dev/null)"

t_case "RUSTFLAGS or CARGO_ENCODED_RUSTFLAGS would override the per-target flags: refused"
t_assert_eq "1|||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=lld RUSTFLAGS=-Copt-level=2)"
t_assert_eq "1|||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=lld CARGO_ENCODED_RUSTFLAGS=-Copt-level=2)"

t_case "a driver that cannot link with the linker fails before anything is exported"
t_assert_eq "1|||" "$(_sel - "${_WORK}/badcc:${P}" KATAGLYPHIS_LINKER=lld)"

t_case "no rustc: C/C++ only"
t_assert_eq "0|-fuse-ld=lld||" "$(_sel - "${_WORK}/norust:${SYS}" KATAGLYPHIS_LINKER=lld)"

t_case "mold on PATH with clang: the LLVMgold plugin rides along, nothing is downloaded"
rm -f "${_WORK}/download.log"
t_assert_eq "0|-fuse-ld=mold -Wl,-plugin,${_WORK}/llvm/lib/LLVMgold.so|clang|-C link-arg=-fuse-ld=mold" \
  "$(_sel - "${_WORK}/moldbin:${_WORK}/llvm/bin:${P}" KATAGLYPHIS_LINKER=mold CC=clang)"
t_assert_eq "absent" "$([[ -f "${_WORK}/download.log" ]] && echo present || echo absent)"

t_case "mold with GCC's driver: no plugin flag, collect2 brings its own"
t_assert_eq "0|-fuse-ld=mold|cc|-C link-arg=-fuse-ld=mold" "$(_sel - "${_WORK}/moldbin:${P}" KATAGLYPHIS_LINKER=mold)"

if PATH="${SYS}" command -v ld.mold >/dev/null 2>&1; then
  printf '  SKIP the download cases: this host has ld.mold in %s\n' "${SYS}"
  t_summary
  exit $?
fi

t_case "mold absent: the versions.env pin is fetched once, then reused from the cache"
pin_ver="$(sed -n 's/^MOLD_LINUX_VERSION=//p' "${VERSIONS}")"
pin_sha="$(sed -n 's/^MOLD_LINUX_X86_64_SHA256=//p' "${VERSIONS}")"
rm -f "${_WORK}/download.log"
t_assert_eq "0|-fuse-ld=mold|cc|-C link-arg=-fuse-ld=mold|${_WORK}/cache/mold-${pin_ver}-x86_64-linux/bin/ld.mold" \
  "$(_sel show "${P}" KATAGLYPHIS_LINKER=mold LINKER_SELECT_CACHE_DIR="${_WORK}/cache")"
t_assert_eq "${pin_sha}" "$(cat "${_WORK}/download.log")"
_sel - "${P}" KATAGLYPHIS_LINKER=mold LINKER_SELECT_CACHE_DIR="${_WORK}/cache" >/dev/null
t_assert_eq "1" "$(wc -l < "${_WORK}/download.log" | tr -d ' ')" "the second run reuses the cache"

t_case "the environment's pin wins over versions.env"
rm -f "${_WORK}/download.log"
t_assert_eq "0|-fuse-ld=mold|cc|-C link-arg=-fuse-ld=mold|${_WORK}/cache2/mold-9.9.9-aarch64-linux/bin/ld.mold" \
  "$(_sel show "${P}" KATAGLYPHIS_LINKER=mold LINKER_SELECT_CACHE_DIR="${_WORK}/cache2" \
    STUB_UNAME_M=aarch64 MOLD_LINUX_VERSION=9.9.9 MOLD_LINUX_AARCH64_SHA256=feedface)"
t_assert_eq "feedface" "$(cat "${_WORK}/download.log")"

t_case "an architecture with no pinned release fails, it never links with something else"
t_assert_eq "1|||" "$(_sel - "${P}" KATAGLYPHIS_LINKER=mold STUB_UNAME_M=s390x LINKER_SELECT_CACHE_DIR="${_WORK}/cache3")"

t_summary
