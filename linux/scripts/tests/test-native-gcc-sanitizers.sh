#!/usr/bin/env bash
# The Canadian native GCC (host == target) builds, installs and ships libsanitizer; the swap
# and the wrapper smoke refuse an image without it; the runtime battery RUNs a sanitized
# binary only natively. build-gcc.sh is top-level, so its regions run with make stubbed.
# NOT covered: whether libsanitizer builds in a Canadian cross, or a sanitized binary really
# runs -- only a Linux chain run shows that. docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BUILD_GCC="${TESTS_DIR}/../02-toolchain/build-gcc.sh"
SWAP="${TESTS_DIR}/../06-packaging/swap-native-gcc.sh"
VALIDATE="${TESTS_DIR}/../06-packaging/validate-compilers.sh"
PLATFORM="${TESTS_DIR}/../01-core/platform.sh"
GCCV=16.2.0
ARM64_LIBS=(asan ubsan lsan tsan hwasan)

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

_so() { case "$1" in asan) echo 8 ;; ubsan) echo 1 ;; tsan) echo 2 ;; *) echo 0 ;; esac; }
# _tree <prefix> <triplet|-> <libdir> <e_machine> <lib>... -- a fake installed GCC prefix
_tree() {
  local p="$1" trip="$2" dir="$3" mach="$4" lib
  shift 4
  rm -rf "${p}"
  mkdir -p "${p}/bin" "${p}/${dir}"
  t_fake_elf "${p}/bin/gcc" "${mach}"
  if [ "${trip}" != - ]; then
    mkdir -p "${p}/lib/gcc/${trip}/${GCCV}/include/sanitizer"
    : > "${p}/lib/gcc/${trip}/${GCCV}/include/sanitizer/common_interface_defs.h"
  fi
  for lib in "$@"; do t_fake_elf "${p}/${dir}/lib${lib}.so.$(_so "${lib}").0.0" "${mach}"; done
}
# _with_rc <command...> -> its combined output, then rc=<n>; _rc_of reads that line back
_with_rc() { local out rc=0; out="$("$@" 2>&1)" || rc=$?; printf '%s\nrc=%s\n' "${out}" "${rc}"; }
_rc_of() { printf '%s\n' "$1" | sed -n 's/^rc=//p'; }

# ── build-gcc.sh: which configurations build libsanitizer ──────────────────
t_case "_gcc_extra_target_libs names libsanitizer for host == target only"
_extra="$(t_fn_src "${BUILD_GCC}" _gcc_extra_target_libs)" || exit 1
_extra_for() { HOST_TRIPLET="$1" TARGET_TRIPLET="$2" bash -c 'set -eu; eval "$1"; _gcc_extra_target_libs' _ "${_extra}"; }
t_assert_eq "target-libsanitizer" "$(_extra_for aarch64-linux-gnu aarch64-linux-gnu)" "Canadian native"
t_assert_eq "" "$(_extra_for "" aarch64-linux-gnu)" "a plain cross compiler is not the defect"
t_assert_eq "" "$(_extra_for x86_64-linux-gnu aarch64-linux-gnu)" "a Canadian with host != target"
t_assert_eq "" "$(_extra_for "" "")" "the full make already builds it"

# Both regions -- the make block, and install through finish_libtool_dirs -- run under the
# script's own IFS with make stubbed to print its targets, so an empty word shows as [].
awk '/^_gcc_extra_target_libs\(\) \{$/{p=1} p{print} p && /^fi$/{exit}' "${BUILD_GCC}" > "${_work}/regions.sh"
awk '/^echo "Installing to /{p=1} p{print} p && /^finish_libtool_dirs$/{exit}' "${BUILD_GCC}" >> "${_work}/regions.sh"
_gcc_run() {  # <host> <target> <prefix> -> build targets, the install banner, install targets, verdict
  _with_rc env HOST_TRIPLET="$1" TARGET_TRIPLET="$2" PREFIX="$3" GCC_VERSION="${GCCV}" bash -c '
    set -euo pipefail; IFS="$1"; JOBS=4; SUDO=""
    make() { printf "[%s]" "$@"; echo; }
    filter_libtool_finish_warnings() { cat >/dev/null; }
    die() { echo "DIE $*"; exit 1; }
    finish_libtool_dirs() { echo FINISHED; }
    source "$2"' _ $'\n\t' "${_work}/regions.sh"
}
_nth() { printf '%s\n' "$1" | sed -n "$2p"; }
_BASE="[all-gcc][all-target-libgcc][all-target-libstdc++-v3][all-target-libatomic]"
_IBASE="[install-gcc][install-target-libgcc][install-target-libstdc++-v3][install-target-libatomic]"

t_case "the Canadian native builds AND installs libsanitizer (the half-fix trap)"
_tree "${_work}/a64" aarch64-linux-gnu lib64 183 asan
_out="$(_gcc_run aarch64-linux-gnu aarch64-linux-gnu "${_work}/a64")"
t_assert_eq "[-j4]${_BASE}[all-target-libsanitizer]" "$(_nth "${_out}" 1)" "built"
t_assert_eq "${_IBASE}[install-target-libsanitizer]" "$(_nth "${_out}" 3)" "built but never installed ships nothing"
t_assert_eq "FINISHED" "$(_nth "${_out}" 4)"
t_assert_eq "0" "$(_rc_of "${_out}")"

t_case "a plain cross and a host != target Canadian keep the trimmed list, with no empty word"
_out="$(_gcc_run "" aarch64-linux-gnu "${_work}/none")"
t_assert_eq "[-j4]${_BASE}" "$(_nth "${_out}" 1)" "plain cross"
t_assert_eq "${_IBASE}" "$(_nth "${_out}" 3)" "plain cross"
t_assert_eq "0" "$(_rc_of "${_out}")" "no libsanitizer asked for, none asserted"
_out="$(_gcc_run x86_64-linux-gnu aarch64-linux-gnu "${_work}/none")"
t_assert_eq "[-j4]${_BASE}" "$(_nth "${_out}" 1)" "host != target"

t_case "the full make stays a bare make / make install"
_out="$(_gcc_run "" "" "${_work}/none")"
t_assert_eq "[-j4]" "$(_nth "${_out}" 1)"
t_assert_eq "[install]" "$(_nth "${_out}" 3)"

t_case "an install that produced no libsanitizer fails the GCC build"
rm -rf "${_work}/none"
_out="$(_gcc_run aarch64-linux-gnu aarch64-linux-gnu "${_work}/none")"
t_assert_contains "${_out}" "DIE libsanitizer installed no headers/libasan for aarch64-linux-gnu" \
  "the silent SANITIZER_SUPPORTED=no path must not ship green"
t_assert_eq "1" "$(_rc_of "${_out}")"
_tree "${_work}/hdr" aarch64-linux-gnu lib64 183
_out="$(_gcc_run aarch64-linux-gnu aarch64-linux-gnu "${_work}/hdr")"
t_assert_eq "1" "$(_rc_of "${_out}")" "headers without libasan are not a runtime"
_tree "${_work}/lib" - lib64 183 asan
_out="$(_gcc_run aarch64-linux-gnu aarch64-linux-gnu "${_work}/lib")"
t_assert_eq "1" "$(_rc_of "${_out}")" "libasan without the header abseil includes"

t_case "riscv64's target libs live in lib/, and the producer check accepts that"
_tree "${_work}/rv" riscv64-linux-gnu lib 243 asan
_out="$(_gcc_run riscv64-linux-gnu riscv64-linux-gnu "${_work}/rv")"
t_assert_eq "FINISHED" "$(_nth "${_out}" 4)"

# ── swap-native-gcc.sh: the shipped prefix, on every build-host shape ────────
_OPT="${_work}/opt"
_swap_fns="$({ t_fn_src "${SWAP}" _assert_native_gcc_sanitizers; t_fn_src "${SWAP}" main; } | sed "s|/opt/gcc-|${_OPT}/gcc-|g")"
_san_check() {  # <prefix> <arch>
  _with_rc env GCC_VERSION="${GCCV}" bash -c 'set -euo pipefail; source "$1"; eval "$2"; _assert_native_gcc_sanitizers "$3" "$4"' \
    _ "${PLATFORM}" "${_swap_fns}" "$1" "$2"
}
# main() with its host-only steps stubbed to name themselves; everything else is real.
_swap_main() {  # <target-arch> <build-arch>
  _with_rc env TARGET_ARCH="$1" BUILDARCH="$2" BUILD_MODE=cross GCC_VERSION="${GCCV}" bash -c '
    set -euo pipefail; source "$1"
    for f in _assert_and_relocate_native_gcc _link_multiarch_dirs _write_native_gcc_profile_d \
             _wrap_native_gcc_drivers _smoke_native_gcc; do eval "${f}() { echo STEP ${f}; }"; done
    eval "$2"; main' _ "${PLATFORM}" "${_swap_fns}"
}
_P="${_OPT}/gcc-${GCCV}"

t_case "a full runtime passes on each arch's own layout"
_tree "${_P}" aarch64-linux-gnu lib64 183 "${ARM64_LIBS[@]}"
t_assert_eq "0" "$(_rc_of "$(_san_check "${_P}" arm64)")" "arm64: lib64, hwasan included"
_tree "${_P}" riscv64-linux-gnu lib 243 asan ubsan lsan tsan
t_assert_eq "0" "$(_rc_of "$(_san_check "${_P}" riscv64)")" "riscv64: lib/, no hwasan"
_tree "${_P}" x86_64-pc-linux-gnu lib64 62 "${ARM64_LIBS[@]}"
t_assert_eq "0" "$(_rc_of "$(_san_check "${_P}" amd64)")" "the full make's config.guess triplet"

t_case "each missing piece fails and is named"
_tree "${_P}" aarch64-linux-gnu lib64 183 asan ubsan lsan tsan
_out="$(_san_check "${_P}" arm64)"
t_assert_eq "1" "$(_rc_of "${_out}")" "arm64 GCC builds hwasan, so an image without it is short"
t_assert_contains "${_out}" "lacks the sanitizer runtime: libhwasan.so"
_tree "${_P}" - lib64 183 "${ARM64_LIBS[@]}"
_out="$(_san_check "${_P}" arm64)"
t_assert_eq "1" "$(_rc_of "${_out}")"
t_assert_contains "${_out}" "sanitizer/common_interface_defs.h" "the header abseil includes"

t_case "libubsan, liblsan and libtsan are each required on their own (arm64 lib64, riscv64 lib/)"
_without() { local x; for x in "${@:2}"; do [ "${x}" = "$1" ] || printf '%s\n' "${x}"; done; }
for _lib in ubsan lsan tsan; do
  mapfile -t _rest < <(_without "${_lib}" "${ARM64_LIBS[@]}")
  _tree "${_P}" aarch64-linux-gnu lib64 183 "${_rest[@]}"
  _out="$(_san_check "${_P}" arm64)"
  t_assert_eq "1" "$(_rc_of "${_out}")" "arm64 without lib${_lib}"
  t_assert_contains "${_out}" "lacks the sanitizer runtime: lib${_lib}.so (" "arm64 names lib${_lib} alone"
  mapfile -t _rest < <(_without "${_lib}" asan ubsan lsan tsan)
  _tree "${_P}" riscv64-linux-gnu lib 243 "${_rest[@]}"
  _out="$(_san_check "${_P}" riscv64)"
  t_assert_eq "1" "$(_rc_of "${_out}")" "riscv64 without lib${_lib}"
  t_assert_contains "${_out}" "lacks the sanitizer runtime: lib${_lib}.so (" "riscv64 names lib${_lib} alone"
done

t_case "a builder-arch libasan in a target tree is an ELF MISMATCH"
_tree "${_P}" aarch64-linux-gnu lib64 183 ubsan lsan tsan hwasan
t_fake_elf "${_P}/lib64/libasan.so.8.0.0" 62
_out="$(_san_check "${_P}" arm64)"
t_assert_eq "1" "$(_rc_of "${_out}")"
t_assert_contains "${_out}" "ELF arch MISMATCH"

t_case "main() checks the host-native GCC (amd64, Jetson, X100 build hosts)"
_tree "${_P}" aarch64-unknown-linux-gnu lib64 183
_out="$(_swap_main arm64 arm64)"
t_assert_eq "1" "$(_rc_of "${_out}")" "a native Jetson GCC without the runtime must not pass"
_tree "${_P}" aarch64-unknown-linux-gnu lib64 183 "${ARM64_LIBS[@]}"
t_assert_contains "$(_swap_main arm64 arm64)" "Using host-native arm64 GCC"
_tree "${_P}" riscv64-unknown-linux-gnu lib 243 asan ubsan lsan tsan
t_assert_eq "0" "$(_rc_of "$(_swap_main riscv64 riscv64)")" "the X100's native riscv64 full make"

t_case "main() checks the relocated Canadian GCC after the driver wrap, before the smoke"
_tree "${_P}" aarch64-linux-gnu lib64 183 "${ARM64_LIBS[@]}"
_out="$(_swap_main arm64 amd64)"
t_assert_eq "0" "$(_rc_of "${_out}")"
t_assert_eq "STEP _wrap_native_gcc_drivers|Sanitizer runtime present|STEP _smoke_native_gcc" \
  "$(printf '%s\n' "${_out}" | grep -e '^STEP _wrap' -e '^Sanitizer runtime' -e '^STEP _smoke' \
     | sed 's/ in .*//' | paste -sd'|' -)"
_tree "${_P}" aarch64-linux-gnu lib64 183
_out="$(_swap_main arm64 amd64)"
t_assert_eq "1" "$(_rc_of "${_out}")" "the arm64 image's cc ships without libasan: the defect itself"

# ── A modelled GCC for both smokes: its "link" writes a script whose NEEDED lines readelf prints
# STUB_NO_SAN_HEADER/_LIBS are the defect's halves; STUB_AS_NEEDED keeps libubsan only for a UBSan call.
_STUB="${_work}/bin"
mkdir -p "${_STUB}" "${_work}/bt"
cat > "${_STUB}/g++" <<'EOF'
#!/usr/bin/env bash
out="" src="" san="" prev=""
for a in "$@"; do
  case "${prev}" in -o) out="${a}" ;; esac
  case "${a}" in
    -dumpversion) echo 16.2.0; exit 0 ;;
    -dumpmachine) echo x86_64-linux-gnu; exit 0 ;;
    -fsanitize=*) san="${a#-fsanitize=}" ;;
    *.c|*.cpp) src="${a}" ;;
  esac
  prev="${a}"
done
if [ "${STUB_NO_SAN_HEADER:-0}" = 1 ] && grep -q '#include <sanitizer/common_interface_defs.h>' "${src}"; then
  echo "${src}:1:10: fatal error: sanitizer/common_interface_defs.h: No such file or directory" >&2; exit 1
fi
if [ -n "${san}" ] && [ "${STUB_NO_SAN_LIBS:-0}" = 1 ]; then echo "ld: cannot find -lasan" >&2; exit 1; fi
{
  echo '#!/bin/sh'
  case "${san}" in *address*) echo '# NEEDED libasan.so.8' ;; esac
  case "${san}" in *undefined*)
    # C++20 instruments no shift base, so only a variable exponent leaves a UBSan call.
    if [ "${STUB_AS_NEEDED:-0}" != 1 ] || grep -Eq '(<<|>>) *[A-Za-z_]' "${src}"; then echo '# NEEDED libubsan.so.1'; fi ;;
  esac
  if grep -q 'cxx-ok' "${src}"; then echo 'echo cxx-ok'; elif grep -q 'c-ok' "${src}"; then echo 'echo c-ok'; fi
  if [ -n "${san}" ]; then
    echo 'case "${ASAN_OPTIONS:-}" in *detect_leaks=0*) ;; *) echo "LeakSanitizer has encountered a fatal error" >&2; exit 1 ;; esac'
    echo 'exit "${SAN_BIN_RC:-0}"'
  fi
} > "${out}"
chmod +x "${out}"
EOF
cp "${_STUB}/g++" "${_STUB}/gcc"
cat > "${_STUB}/readelf" <<'EOF'
#!/usr/bin/env bash
if [ -n "${READELF_OUT+set}" ]; then printf '%s\n' "${READELF_OUT}"; exit 0; fi
sed -n 's/^# NEEDED \(.*\)$/ 0x0000000000000001 (NEEDED)             Shared library: [\1]/p' "${@: -1}"
EOF
chmod +x "${_STUB}/g++" "${_STUB}/gcc" "${_STUB}/readelf"
_N_ASAN=' 0x0000000000000001 (NEEDED)             Shared library: [libasan.so.8]'
_N_UBSAN=' 0x0000000000000001 (NEEDED)             Shared library: [libubsan.so.1]'

# ── validate-compilers.sh: the wrapper-smoke compile+link ──────────────────
_vc_fns="$(t_fn_src "${VALIDATE}" validate_fail; t_fn_src "${VALIDATE}" _smoke_gcc_sanitizers)"
_vc_run() {  # [VAR=val...] -> the real _smoke_gcc_sanitizers against whatever g++/readelf PATH finds
  env "$@" bash -c 'set -euo pipefail; _VALIDATE_ERRORS=0; eval "$1"; _smoke_gcc_sanitizers
    echo "ERRORS=${_VALIDATE_ERRORS}"' _ "${_vc_fns}" 2>&1
}
_vc_smoke() { _vc_run PATH="${_STUB}:${PATH}" "$@"; }  # the same, on the modelled GCC

t_case "the smoke passes on a GCC that ships the runtime, --as-needed or not"
t_assert_contains "$(_vc_smoke)" "ERRORS=0"
t_assert_contains "$(_vc_smoke STUB_AS_NEEDED=1)" "ERRORS=0" "the TU must call UBSan, or --as-needed drops libubsan"

t_case "the smoke fails on each half of the defect, and when a runtime is not NEEDED"
_out="$(_vc_smoke STUB_NO_SAN_HEADER=1)"
t_assert_contains "${_out}" "COMPILER FAIL [gcc-sanitizers]" "the TU must include the header abseil includes"
t_assert_contains "${_out}" "fatal error: sanitizer/common_interface_defs.h" "and the log must say why"
t_assert_contains "${_out}" "ERRORS=1"
t_assert_contains "$(_vc_smoke STUB_NO_SAN_LIBS=1)" "ERRORS=1" "a header without libasan is not a runtime"
t_assert_contains "$(_vc_smoke READELF_OUT="${_N_UBSAN}")" "ERRORS=1" "linked, but not against libasan"
t_assert_contains "$(_vc_smoke READELF_OUT="${_N_ASAN}")" "ERRORS=1" "linked, but not against libubsan"

t_case "validate_smoke calls it -- a gate nothing invokes is not a gate"
t_assert_contains "$(t_fn_src "${VALIDATE}" validate_smoke)" "_smoke_gcc_sanitizers"

t_case "a real g++ that links -fsanitize passes the smoke (SKIP where this host cannot)"
printf 'int main(){return 0;}\n' > "${_work}/p.cpp"
if command -v g++ >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1 \
   && g++ -fsanitize=address,undefined "${_work}/p.cpp" -o "${_work}/p" >/dev/null 2>&1 \
   && readelf -d "${_work}/p" 2>/dev/null | grep -q -e 'libasan'; then
  t_assert_contains "$(_vc_run)" "ERRORS=0" "the host links -fsanitize, so the real TU must"
else
  echo "  SKIP real-toolchain case: this host's g++ cannot link -fsanitize=address,undefined (not counted)"
fi

# ── smoke-runtime-image.sh: the battery's sanitizer case ────────────────────
# Here, not in test-runtime-image-gates.sh: that suite is red on a Windows host, where
# neither a mutation proof nor the hook could run against it.
_bat_fn="$(t_fn_src "${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh" check_native_compiler_battery)" || exit 1
_battery() {  # <target-arch> <host-arch> [VAR=val...] -> its report, the bash -lc body RUN on the modelled GCC
  local target="$1" host="$2"; shift 2
  env "$@" HOST_STUB="${host}" STUB_PATH="${_STUB}:${PATH}" TMPDIR="${_work}/bt" bash -c 'set -u
    pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; }
    RUNTIME_COMPILER_SMOKE=1
    smoke_host_arch() { printf "%s" "${HOST_STUB}"; }
    _rt_run() {
      local -a envs=()
      while [ "$1" = -e ]; do envs+=("$2"); shift 2; done
      [ "$1 $2" = "bash -lc" ] || { echo "STUB: _rt_run got $1 $2"; return 99; }
      env "${envs[@]}" PATH="${STUB_PATH}" bash -c "$3"
    }
    eval "$1"; check_native_compiler_battery img "$2"' _ "${_bat_fn}" "${target}" 2>&1
}
_RUN="C++ sanitizer RUN (native)"
_CL="C++ -fsanitize=address,undefined compile+link"
_SKIP="sanitizer RUN skipped: emulated arch"

t_case "the sanitizer binary RUNs on the build host's own arch, and only there"
_out="$(_battery amd64 amd64)"
t_assert_contains "${_out}" "  OK  ${_RUN}" "amd64 on the amd64 host runs natively"
t_assert_contains "${_out}" "PASS native compiler battery" "the whole battery runs on the modelled GCC"
t_assert_contains "$(_battery riscv64 riscv64)" "  OK  ${_RUN}" "the X100 runs its own riscv64 image"
_emu="$(_battery arm64 amd64)"
t_assert_contains "${_emu}" "${_SKIP}" "an emulated arm64 image must not run ASan, and says so"
t_assert_eq "0" "$(printf '%s\n' "${_emu}" | grep -cF "${_RUN}")" "no RUN verdict under qemu"
t_assert_contains "$(_battery amd64 arm64)" "${_SKIP}" "nor an amd64 image under qemu on a Jetson"

t_case "a failing sanitized binary fails the battery natively; under qemu it is never run"
_out="$(_battery amd64 amd64 SAN_BIN_RC=1)"
t_assert_contains "${_out}" "  XX  ${_RUN}"
t_assert_contains "${_out}" "FAIL native compiler battery"
t_assert_contains "$(_battery arm64 amd64 SAN_BIN_RC=1)" "PASS native compiler battery"

t_case "the battery compiles the header abseil includes and links both runtimes"
t_assert_contains "${_emu}" "  OK  ${_CL}"
t_assert_contains "$(_battery arm64 amd64 STUB_AS_NEEDED=1)" "  OK  ${_CL}" "the TU must call UBSan, or --as-needed drops libubsan"
_out="$(_battery arm64 amd64 STUB_NO_SAN_HEADER=1)"
t_assert_contains "${_out}" "  XX  ${_CL}" "the header half of the arm64 defect"
t_assert_contains "${_out}" "FAIL native compiler battery"
t_assert_contains "$(_battery arm64 amd64 STUB_NO_SAN_LIBS=1)" "  XX  ${_CL}" "the libasan half"
t_assert_contains "$(_battery arm64 amd64 READELF_OUT="${_N_ASAN}")" "  XX  ${_CL}" "linked, but not against libubsan"

t_summary
