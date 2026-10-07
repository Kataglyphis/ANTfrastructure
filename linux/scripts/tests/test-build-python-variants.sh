#!/usr/bin/env bash
# build_python.sh's free-threaded twin and the toolchain smoke that grades it; see docs/consumer-image-contract.md#the-free-threaded-python
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
BUILD_PY="${TESTS_DIR}/../02-toolchain/python/build_python.sh"
PC_FIX="${TESTS_DIR}/../02-toolchain/python/fix-staged-python-pc.sh"
SMOKE_TC="${TESTS_DIR}/../06-packaging/smoke-toolchain.sh"

_fns=""
for _f in python_variant_select python_cross_stage_root_for_arch python_cross_stage_prefix_for_arch \
          python_stage_finalize stage_host_python_payload _python_dynload_audit; do
  _fns+="$(t_fn_src "${BUILD_PY}" "${_f}")"$'\n' || exit 1
done
# The collaborators build_python.sh sources from 01-core, stubbed; err exits like logging.sh's.
_STUBS='info() { :; }; warn() { printf "WARN %s\n" "$*"; }; err() { printf "ERR %s\n" "$*"; exit 1; }
arch_normalize() { printf "%s" "$1"; }
arch_deb_multiarch_triplet_for() { case "$1" in amd64) echo x86_64-linux-gnu ;; arm64) echo aarch64-linux-gnu ;; esac; }
PYTHON_MAJOR_MINOR=3.14; PYTHON_VERSION=3.14.7; PYTHON_SOURCE_DIR=/tmp/Python-3.14.7
PYTHON_CROSS_STAGE_ROOT=/opt/python-cross; PYTHON_FT_SOURCE_PARENT=/tmp/Python-3.14.7-ft-src
PYTHON_FT_PREFIX=/opt/python-freethreaded; PYTHON_FT_CROSS_STAGE_ROOT=/opt/python-cross-ft'

# _bp <body>: the extracted functions in a fresh bash, with the stubs and the pc fixer.
_bp() {
  bash -c "${_STUBS}"$'\n'"source '${PC_FIX}'"$'\n'"${_fns}"$'\n'"$1" 2>&1
}

# Each variant's PY_* values, one call per variant, read by the two cases below.
_VARS='printf "%s|%s|%s|%s|%s\n" "${PY_LDVERSION}" "${PY_PREFIX}" "${PY_STAGE_ROOT}" "${PY_SOURCE_DIR}" "${#PY_CONFIGURE_EXTRA[@]}"
printf "ARG %s\n" "${PY_CONFIGURE_EXTRA[@]}"
python_cross_stage_prefix_for_arch arm64'
_gil="$(_bp "python_variant_select gil"$'\n'"${_VARS}")"
_out="$(_bp "python_variant_select freethreaded"$'\n'"${_VARS}")"

t_case "the GIL variant keeps the values every helper hard-coded before the twin existed"
t_assert_eq "3.14|/usr/local|/opt/python-cross|/tmp/Python-3.14.7|0" "$(printf '%s\n' "${_gil}" | head -1)"
t_assert_contains "${_gil}" "/opt/python-cross/arm64/usr/local" "the GIL stage layout is unchanged"

t_case "the free-threaded variant is --disable-gil in its own prefix, stage root and source tree (mutation)"
t_assert_contains "${_out}" "3.14t|/opt/python-freethreaded|/opt/python-cross-ft|/tmp/Python-3.14.7-ft-src/Python-3.14.7|"
t_assert_contains "${_out}" "ARG --disable-gil" "the GIL stays on without it"
t_assert_contains "${_out}" "ARG LDFLAGS_NODIST=-Wl,-rpath,/opt/python-freethreaded/lib" \
  "the binary finds its libpython without an ld.so.conf entry, and sysconfig's LDFLAGS stay clean"
t_assert_contains "${_out}" "ARG --without-static-libpython" "the shipped tree carries no fat-LTO archive nothing links"
t_assert_contains "${_out}" "/opt/python-cross-ft/arm64/opt/python-freethreaded" "the stage mirrors the install prefix"

t_case "an unknown PYTHON_VARIANTS entry stops the build"
t_assert_contains "$(_bp 'python_variant_select nogil; echo SURVIVED')" "ERR Unknown CPython variant 'nogil'"
t_assert_eq "0" "$(_bp 'python_variant_select nogil; echo SURVIVED' | grep -c SURVIVED || true)"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

t_case "the build arch's free-threaded prefix stages whole, relocatable, and answers only to its t names"
_ftp="${_work}/opt/python-freethreaded"
mkdir -p "${_ftp}/bin" "${_ftp}/lib/pkgconfig" "${_ftp}/lib/python3.14t/lib-dynload" "${_ftp}/include/python3.14t"
printf '#!/bin/sh\n' > "${_ftp}/bin/python3.14t"; chmod +x "${_ftp}/bin/python3.14t"
: > "${_ftp}/lib/libpython3.14t.so.1.0"; : > "${_ftp}/lib/python3.14t/os.py"; : > "${_ftp}/include/python3.14t/pyconfig.h"
mkdir -p "${_ftp}/lib/python3.14t/test"; : > "${_ftp}/lib/python3.14t/test/test_os.py"
printf 'prefix=%s\nexec_prefix=${prefix}\nlibdir=${exec_prefix}/lib\n' "${_ftp}" > "${_ftp}/lib/pkgconfig/python-3.14t.pc"
_out="$(_bp "PYTHON_FT_PREFIX='${_ftp}'; PYTHON_FT_CROSS_STAGE_ROOT='${_work}/stage'
python_variant_select freethreaded
stage_host_python_payload amd64 && echo STAGED")"
_st="${_work}/stage/amd64${_ftp}"
t_assert_contains "${_out}" "STAGED"
for _p in bin/python3.14t lib/libpython3.14t.so.1.0 lib/python3.14t/os.py include/x86_64-linux-gnu/python3.14t/pyconfig.h; do
  t_assert_eq "yes" "$([ -e "${_st}/${_p}" ] && echo yes || echo no)" "${_p} staged"
done
t_assert_eq 'prefix=${pcfiledir}/../..' "$(sed -n 1p "${_st}/lib/pkgconfig/python-3.14t.pc")" \
  "the staged pc file resolves wherever the tree lands"
t_assert_eq "prefix=${_ftp}" "$(sed -n 1p "${_ftp}/lib/pkgconfig/python-3.14t.pc")" \
  "rewriting the staged copy must not reach the installed prefix through the hardlink"
t_assert_eq "no|no" "$([ -e "${_st}/bin/python3" ] && echo yes || echo no)|$([ -e "${_st}/lib/pkgconfig/python3.pc" ] && echo yes || echo no)" \
  "python3 and python3.pc keep meaning the GIL build"
t_assert_eq "no|yes" "$([ -e "${_st}/lib/python3.14t/test" ] && echo yes || echo no)|$([ -e "${_ftp}/lib/python3.14t/test/test_os.py" ] && echo yes || echo no)" \
  "the shipped tree drops the test suite, as the cross trees do, and the toolchain's own keeps it"

t_case "a native build stages the free-threaded tree for its own arch, and still no GIL tree (mutation)"
_snp="$(t_fn_src "${BUILD_PY}" stage_requested_cross_python_payloads)" || exit 1
_sn_run() {
  bash -c "${_STUBS}"$'\n'"${_fns}"$'\n'"${_snp}"$'\n'"build_arch_oci() { echo amd64; }
stage_host_python_payload() { echo \"HOST \$1 \${PY_VARIANT}\"; }
BUILD_MODE=native; PYTHON_FT_CROSS_STAGE_ROOT='${_work}/ns'; PYTHON_CROSS_STAGE_ROOT='${_work}/ngs'
python_variant_select $1; stage_requested_cross_python_payloads" 2>&1
}
t_assert_eq "HOST amd64 freethreaded" "$(_sn_run freethreaded)" "Dockerfile.package COPYs this tree in native mode too"
t_assert_eq "" "$(_sn_run gil)" "the native GIL build keeps staging nothing"

t_case "the GIL stage still gets its unversioned links"
t_needs "real symlinks" t_posix_symlinks
_gs="${_work}/gstage"
mkdir -p "${_gs}/usr/local/bin" "${_gs}/usr/local/lib/pkgconfig" "${_gs}/usr/local/include/python3.14"
printf '#!/bin/sh\n' > "${_gs}/usr/local/bin/python3.14"; chmod +x "${_gs}/usr/local/bin/python3.14"
printf 'prefix=/usr/local\n' > "${_gs}/usr/local/lib/pkgconfig/python-3.14.pc"
_bp "python_variant_select gil; python_stage_finalize arm64 '${_gs}' 3.14 aarch64-linux-gnu" >/dev/null
t_assert_eq "python3.14|python-3.14.pc" "$(readlink "${_gs}/usr/local/bin/python3" 2>/dev/null)|$(readlink "${_gs}/usr/local/lib/pkgconfig/python3.pc" 2>/dev/null)"
t_assert_eq 'prefix=${pcfiledir}/../..' "$(sed -n 1p "${_gs}/usr/local/lib/pkgconfig/python-3.14.pc")" "the default prefix is still /usr/local"

t_case "the shipped free-threaded tree must carry what the image smoke imports; the GIL tree only warns (mutation)"
_dl="${_work}/dynload"; mkdir -p "${_dl}"
for _e in _struct math cmath _csv _json _pickle _socket _ssl _hashlib _sqlite3 zlib _bz2 _lzma; do
  : > "${_dl}/${_e}.cpython-314t-aarch64-linux-gnu.so"
done
_dl_run() { _bp "source '${TESTS_DIR}/../01-core/cpython-dev-packages.sh'; python_variant_select $1; _python_dynload_audit '${_dl}' && echo AUDIT_OK"; }
t_assert_contains "$(_dl_run freethreaded)" "ERR target Python is missing critical C extensions" "no _ctypes in the free-threaded tree"
t_assert_contains "$(_dl_run gil)" "AUDIT_OK" "the GIL tree's _ctypes is off on purpose"
t_assert_contains "$(_dl_run gil)" "WARN Optional C extension missing: _ctypes"
: > "${_dl}/_ctypes.cpython-314t-aarch64-linux-gnu.so"
t_assert_contains "$(_dl_run freethreaded)" "AUDIT_OK"

t_case "the toolchain smoke grades the twin and every staged arch, the build arch's included (mutation)"
_tc="$(t_fn_src "${SMOKE_TC}" check_free_threaded_python | sed -e "s|/usr/local/bin/|${_work}/smk/bin/|" -e "s|/opt/python-cross-ft/|${_work}/smk/ft/|")" || exit 1
mkdir -p "${_work}/smk/bin"
_tc_run() {
  printf '#!/bin/sh\necho "%s"\n' "$1" > "${_work}/smk/bin/python3.14t"; chmod +x "${_work}/smk/bin/python3.14t"
  bash -c 'pass() { printf "PASS %s\n" "$*"; }; fail() { printf "FAIL %s\n" "$*"; }
    smoke_arch_words() { printf "%s\n" "${1:-}" | tr ", " "\n\n"; }
    PYTHON_MAJOR_MINOR=3.14; PYTHON_VERSION=3.14.7
    '"${_tc}"'
    check_free_threaded_python amd64,arm64' 2>&1
}
for _a in amd64 arm64; do
  mkdir -p "${_work}/smk/ft/${_a}/opt/python-freethreaded/bin" "${_work}/smk/ft/${_a}/opt/python-freethreaded/lib/pkgconfig"
  printf '#!/bin/sh\n' > "${_work}/smk/ft/${_a}/opt/python-freethreaded/bin/python3.14t"
  chmod +x "${_work}/smk/ft/${_a}/opt/python-freethreaded/bin/python3.14t"
  : > "${_work}/smk/ft/${_a}/opt/python-freethreaded/lib/pkgconfig/python-3.14t.pc"
done
_out="$(_tc_run '3.14.7 False 1')"
t_assert_contains "${_out}" "PASS python3.14t 3.14.7 runs without the GIL"
t_assert_contains "${_out}" "PASS free-threaded Python 3.14t staged for amd64"
t_assert_contains "${_out}" "PASS free-threaded Python 3.14t staged for arm64"
t_assert_eq "0" "$(printf '%s\n' "${_out}" | grep -c '^FAIL' || true)"
t_assert_contains "$(_tc_run '3.14.7 True 0')" "FAIL python3.14t reports '3.14.7 True 0', expected '3.14.7 False 1'"
t_assert_contains "$(_tc_run "ModuleNotFoundError: No module named '_ctypes'")" "FAIL python3.14t reports 'ModuleNotFoundError"
rm -f "${_work}/smk/ft/arm64/opt/python-freethreaded/lib/pkgconfig/python-3.14t.pc"
t_assert_contains "$(_tc_run '3.14.7 False 1')" "FAIL free-threaded Python 3.14t not staged for arm64"

t_summary
