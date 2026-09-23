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

# ── validate-compilers.sh: the wrapper-smoke compile+link ──────────────────
_vc_fns="$(t_fn_src "${VALIDATE}" validate_fail; t_fn_src "${VALIDATE}" _smoke_gcc_sanitizers)"
mkdir -p "${_work}/bin"
cat > "${_work}/bin/g++" <<'EOF'
#!/usr/bin/env bash
[ "$GXX_RC" = 0 ] || echo "stub g++: forced failure" >&2
exit "$GXX_RC"
EOF
cat > "${_work}/bin/readelf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$READELF_OUT"
EOF
chmod +x "${_work}/bin/g++" "${_work}/bin/readelf"
_vc_run() {  # the real _smoke_gcc_sanitizers against whatever g++/readelf PATH finds
  bash -c 'set -euo pipefail; _VALIDATE_ERRORS=0; eval "$1"; _smoke_gcc_sanitizers
    echo "ERRORS=${_VALIDATE_ERRORS}"' _ "${_vc_fns}" 2>&1
}
_vc_smoke() { PATH="${_work}/bin:${PATH}" GXX_RC="$1" READELF_OUT="$2" _vc_run; }  # <g++ rc> <readelf -d output>
_N_ASAN=' 0x0000000000000001 (NEEDED)             Shared library: [libasan.so.8]'
_N_UBSAN=' 0x0000000000000001 (NEEDED)             Shared library: [libubsan.so.1]'

t_case "the smoke passes only when both runtimes are NEEDED"
t_assert_contains "$(_vc_smoke 0 "${_N_ASAN}
${_N_UBSAN}")" "ERRORS=0"
t_assert_contains "$(_vc_smoke 1 "")" "COMPILER FAIL [gcc-sanitizers]" "a g++ that cannot compile it"
t_assert_contains "$(_vc_smoke 1 "")" "ERRORS=1"
t_assert_contains "$(_vc_smoke 0 "${_N_UBSAN}")" "ERRORS=1" "linked, but not against libasan"
t_assert_contains "$(_vc_smoke 0 "${_N_ASAN}")" "ERRORS=1" "linked, but not against libubsan"

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
_battery() {  # <target-arch> <host-arch> -> the args _rt_run received, one per line
  HOST_STUB="$2" bash -c 'set -u
    pass() { echo "PASS $*"; }; fail() { echo "FAIL $*"; }
    RUNTIME_COMPILER_SMOKE=1
    smoke_host_arch() { printf "%s" "${HOST_STUB}"; }
    _rt_run() { printf "ARG %s\n" "$@"; }
    eval "$1"; check_native_compiler_battery img "$2"' _ "${_bat_fn}" "$1" 2>&1
}

t_case "the sanitizer binary RUNs only on the build host's own arch"
t_assert_contains "$(_battery amd64 amd64)" "ARG SAN_RUN=1" "amd64 on the amd64 host runs natively"
t_assert_contains "$(_battery riscv64 riscv64)" "ARG SAN_RUN=1" "the X100 runs its own riscv64 image"
t_assert_contains "$(_battery arm64 amd64)" "ARG SAN_RUN=0" "an emulated arm64 image must not run ASan"
t_assert_contains "$(_battery amd64 arm64)" "ARG SAN_RUN=0" "nor an amd64 image under qemu on a Jetson"

t_case "the battery compiles the header abseil includes and links both runtimes"
_bat="$(_battery arm64 amd64)"
t_assert_contains "${_bat}" "-fsanitize=address,undefined"
t_assert_contains "${_bat}" "#include <sanitizer/common_interface_defs.h>"
t_assert_contains "${_bat}" 'grep -q "NEEDED.*libasan"'
t_assert_contains "${_bat}" 'grep -q "NEEDED.*libubsan"'
t_assert_contains "${_bat}" "ASAN_OPTIONS=detect_leaks=0" "LSan needs ptrace, which a container RUN may not allow"
t_assert_contains "${_bat}" "sanitizer RUN skipped: emulated arch" "a skip must say so, never read as a pass"

t_summary
