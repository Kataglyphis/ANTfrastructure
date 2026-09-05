#!/usr/bin/env bash
# Both ends of the historical stray-`}` bug: generate_pkgconfig_file
# (01-core/common.sh, backlog T5) which emitted it, and the three helpers the
# GStreamer monorepo splits its TFLite workarounds into (CL6), one of which
# repairs the .pc files older images already shipped.
# docs/cross-build-verification.md#tflite-for-the-gstreamer-monorepo-three-workarounds
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
COMMON_SH="${TESTS_DIR}/../01-core/common.sh"

# Source ONLY the function under test: full common.sh pulls versions.env plus
# five sibling modules at source time (same reason test-cross-fallback-parity
# extracts instead of sourcing). generate_pkgconfig_file is self-contained
# (locals + mkdir + cat), so an awk block extraction is safe.
_fn_src="$(awk '/^generate_pkgconfig_file\(\) \{/,/^\}/' "${COMMON_SH}")"

t_case "generate_pkgconfig_file is extractable from common.sh"
t_assert_contains "${_fn_src}" 'cat >"${pc_path}"' \
  "extraction must capture the whole heredoc body (did the function move?)"
eval "${_fn_src}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# Count '}' characters that are NOT part of a ${var} pkg-config reference —
# the exact artifact the historical bug emitted. Must be 0.
_stray_braces() {
  sed 's/\${[A-Za-z_][A-Za-z_0-9]*}//g' "$1" | grep -n '}' || true
}

# ---------------------------------------------------------------------------
t_case "defaults: Libs/Cflags emitted as UNEXPANDED pkg-config variables"
generate_pkgconfig_file "${tmpdir}/default.pc" testlib "Test library" 1.2.3 /usr/local
t_assert_ok grep -qxF 'Libs: -L${libdir}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Cflags: -I${includedir}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'prefix=/usr/local' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'exec_prefix=${prefix}' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'libdir=${prefix}/lib' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Name: testlib' "${tmpdir}/default.pc"
t_assert_ok grep -qxF 'Version: 1.2.3' "${tmpdir}/default.pc"

t_case "defaults: no stray '}' on any line (the historical :- default bug)"
t_assert_eq "" "$(_stray_braces "${tmpdir}/default.pc")" \
  "a '}' outside a \${var} reference is the tensorflow-lite.pc bug"

t_case "defaults: optional Requires/Libs.private lines are ABSENT"
t_assert_fails grep -q '^Requires:' "${tmpdir}/default.pc"
t_assert_fails grep -q '^Libs\.private:' "${tmpdir}/default.pc"

# ---------------------------------------------------------------------------
t_case "full args: explicit libs/cflags plus Requires and Libs.private lines"
generate_pkgconfig_file "${tmpdir}/full.pc" foo "Foo library" 2.0 /opt/foo \
  '-L${libdir} -lfoo' '-I${includedir}/foo' 'zlib >= 1.2' '-lm -lpthread'
t_assert_ok grep -qxF 'Libs: -L${libdir} -lfoo' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Cflags: -I${includedir}/foo' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Requires: zlib >= 1.2' "${tmpdir}/full.pc"
t_assert_ok grep -qxF 'Libs.private: -lm -lpthread' "${tmpdir}/full.pc"

t_case "full args: still no stray '}' anywhere"
t_assert_eq "" "$(_stray_braces "${tmpdir}/full.pc")"

# ---------------------------------------------------------------------------
# CL6: the three TFLite helpers, extracted the same way and driven under a
# fixture root. The hardcoded /usr/local and /opt/gcc- prefixes are repointed at
# the fixture, which is the only edit made to the bodies.
MONO_SH="${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh"
_extract() { awk "/^$1\(\) \{/,/^\}/" "$2"; }

# _tflite <root> <fn> <preamble> — run one helper in a subshell rooted at <root>,
# echo its rc last. <preamble> stubs whatever the helper's own file would supply.
_tflite() {
  local root="$1" fn="$2" pre="$3" src
  src="$(_extract "${fn}" "${MONO_SH}" \
    | sed -e "s#/usr/local/lib#${root}/usr/local/lib#g" -e "s#/opt/gcc-#${root}/opt/gcc-#g")"
  ( set -euo pipefail
    eval "${pre}"
    eval "${src}"
    "${fn}"
    printf 'RC=%s\n' "$?" ) 2>&1
}

t_case "the three TFLite helpers are extractable, and the parent is just three calls"
for _fn in _gst_tflite_probe_flags _gst_tflite_fix_pc _gst_tflite_symlink_for_meson; do
  t_assert_contains "$(_extract "${_fn}" "${MONO_SH}")" "${_fn}() {" \
    "${_fn} must exist under its own name (did the split get re-merged?)"
  t_assert_contains "$(_extract _gst_monorepo_tflite_flags "${MONO_SH}")" "  ${_fn}" \
    "and the parent must still call it, in order"
done

APPEND_SRC="$(_extract append_flag_if_missing "${COMMON_SH}")"
_PROBE_PRE='cross_build_is_active() { [ "${STUB_CROSS}" = 1 ]; }
'"${APPEND_SRC}"'
CPPFLAGS=""; CFLAGS=""; CXXFLAGS=""; LDFLAGS=""
trap '"'"'printf "CPPFLAGS=%s\nCFLAGS=%s\nCXXFLAGS=%s\nLDFLAGS=%s\n" \
  "${CPPFLAGS}" "${CFLAGS}" "${CXXFLAGS}" "${LDFLAGS}"'"'"' EXIT'

# _pkgconfig <dir> <name>... — a pkg-config stub that only knows <name>...
_pkgconfig() {
  local d="$1"; shift
  mkdir -p "${d}/bin"
  { printf '#!/usr/bin/env bash\nknown="%s"\n' "$*"
    printf 'case "$1" in\n'
    printf '  --exists) case " ${known} " in *" $2 "*) exit 0 ;; esac; exit 1 ;;\n'
    printf '  --variable=includedir) printf "/inc/%%s\\n" "$2" ;;\n'
    printf '  --variable=libdir) printf "/lib/%%s\\n" "$2" ;;\n'
    printf 'esac\n'; } > "${d}/bin/pkg-config"
  chmod +x "${d}/bin/pkg-config"
}

t_case "probe: a native build asks pkg-config nothing and touches no flag"
_r="$(mktemp -d)"; _pkgconfig "${_r}" tensorflowlite_c
_out="$(PATH="${_r}/bin:${PATH}" STUB_CROSS=0 _tflite "${_r}" _gst_tflite_probe_flags "${_PROBE_PRE}")"
t_assert_contains "${_out}" "RC=0" "the skip path must not abort a set -e caller"
t_assert_contains "${_out}" "CPPFLAGS=" "no include flag when not cross-building"
t_assert_eq "" "$(printf '%s' "${_out}" | sed -n 's/^LDFLAGS=//p')"

t_case "probe: cross with no TFLite .pc at all is also a clean no-op"
_n="$(mktemp -d)"; _pkgconfig "${_n}" nothing-at-all
_out="$(PATH="${_n}/bin:${PATH}" STUB_CROSS=1 _tflite "${_n}" _gst_tflite_probe_flags "${_PROBE_PRE}")"
t_assert_contains "${_out}" "RC=0" "nothing found is not a failure"
t_assert_eq "" "$(printf '%s' "${_out}" | sed -n 's/^LDFLAGS=//p')" "and no flag is invented"
rm -rf "${_n}"

t_case "probe: cross emits -idirafter for headers and -L plus -rpath-link for libs"
_out="$(PATH="${_r}/bin:${PATH}" STUB_CROSS=1 _tflite "${_r}" _gst_tflite_probe_flags "${_PROBE_PRE}")"
t_assert_eq "-idirafter /inc/tensorflowlite_c" "$(printf '%s' "${_out}" | sed -n 's/^CPPFLAGS=//p')"
t_assert_eq "-idirafter /inc/tensorflowlite_c" "$(printf '%s' "${_out}" | sed -n 's/^CXXFLAGS=//p')"
t_assert_eq "-L/lib/tensorflowlite_c -Wl,-rpath-link,/lib/tensorflowlite_c" \
  "$(printf '%s' "${_out}" | sed -n 's/^LDFLAGS=//p')" \
  "-idirafter, never -I: the target headers must lose to the toolchain's own"
t_assert_contains "${_out}" "Resolved tensorflowlite_c for Meson probes"

t_case "probe: tensorflowlite_c wins over tensorflow-lite, first match only"
rm -rf "${_r:?}/bin"; _pkgconfig "${_r}" tensorflowlite_c tensorflow-lite
_out="$(PATH="${_r}/bin:${PATH}" STUB_CROSS=1 _tflite "${_r}" _gst_tflite_probe_flags "${_PROBE_PRE}")"
t_assert_contains "${_out}" "Resolved tensorflowlite_c for"
t_assert_eq "-L/lib/tensorflowlite_c -Wl,-rpath-link,/lib/tensorflowlite_c" \
  "$(printf '%s' "${_out}" | sed -n 's/^LDFLAGS=//p')" "the loop must break on the first hit"
rm -rf "${_r}"

_PC_DIR=usr/local/lib/pkgconfig
t_case "fix-pc: the stray brace this very file's first half is about is repaired, once"
_r="$(mktemp -d)"; mkdir -p "${_r}/${_PC_DIR}"
printf 'Libs: -L${libdir} -ltensorflow-lite}\n' > "${_r}/${_PC_DIR}/tensorflow-lite.pc"
t_assert_contains "$(_tflite "${_r}" _gst_tflite_fix_pc '')" "RC=0"
t_assert_eq 'Libs: -L${libdir} -ltensorflow-lite' "$(cat "${_r}/${_PC_DIR}/tensorflow-lite.pc")"
t_assert_eq "" "$(_stray_braces "${_r}/${_PC_DIR}/tensorflow-lite.pc")"
_tflite "${_r}" _gst_tflite_fix_pc '' >/dev/null
t_assert_eq 'Libs: -L${libdir} -ltensorflow-lite' "$(cat "${_r}/${_PC_DIR}/tensorflow-lite.pc")" \
  "a second pass must be a no-op -- the repair runs on every monorepo build"

t_case "fix-pc: a clean .pc and a missing .pc are both left alone, rc 0"
printf 'Libs: -L${libdir} -ltensorflow-lite\n' > "${_r}/${_PC_DIR}/tensorflow-lite.pc"
_tflite "${_r}" _gst_tflite_fix_pc '' >/dev/null
t_assert_eq 'Libs: -L${libdir} -ltensorflow-lite' "$(cat "${_r}/${_PC_DIR}/tensorflow-lite.pc")"
rm -f "${_r}/${_PC_DIR}/tensorflow-lite.pc"
t_assert_contains "$(_tflite "${_r}" _gst_tflite_fix_pc '')" "RC=0" \
  "older images have no .pc at all; that is not a failure"
rm -rf "${_r}"

_SYM_PRE='trap '"'"'printf "LIBRARY_PATH=%s\n" "${LIBRARY_PATH:-}"'"'"' EXIT'
t_case "symlink: cross seeds every gcc search dir Meson's -print-file-name reaches"
_r="$(mktemp -d)"
mkdir -p "${_r}/usr/local/lib" "${_r}/opt/gcc-16/aarch64-linux-gnu/lib64" \
         "${_r}/opt/gcc-16/lib/gcc/riscv64-linux-gnu/16.1.0"
: > "${_r}/usr/local/lib/libtensorflow-lite.so"; : > "${_r}/usr/local/lib/libtensorflow-lite.a"
_out="$(BUILD_MODE=cross _tflite "${_r}" _gst_tflite_symlink_for_meson "${_SYM_PRE}")"
t_assert_contains "${_out}" "RC=0"
t_assert_ok test -L "${_r}/opt/gcc-16/aarch64-linux-gnu/lib64/libtensorflow-lite.so"
t_assert_ok test -L "${_r}/opt/gcc-16/lib/gcc/riscv64-linux-gnu/16.1.0/libtensorflow-lite.a"
t_assert_contains "${_out}" "LIBRARY_PATH=${_r}/usr/local/lib:" \
  "the -L flags pkg-config emits are exactly what -print-file-name ignores"

t_case "symlink: a native build, and a cross build with no library, both do nothing"
find "${_r:?}/opt" -name 'libtensorflow-lite.*' -delete
t_assert_contains "$(BUILD_MODE=native _tflite "${_r}" _gst_tflite_symlink_for_meson "${_SYM_PRE}")" \
  "LIBRARY_PATH=" "native must leave LIBRARY_PATH alone"
t_assert_eq "" "$(find "${_r}/opt" -name 'libtensorflow-lite.so' 2>/dev/null)" \
  "and plants no symlink"
rm -f "${_r}/usr/local/lib/libtensorflow-lite.so"
t_assert_contains "$(BUILD_MODE=cross _tflite "${_r}" _gst_tflite_symlink_for_meson "${_SYM_PRE}")" \
  "RC=0" "no library built yet is a skip, not an abort"
rm -rf "${_r}"

t_summary
