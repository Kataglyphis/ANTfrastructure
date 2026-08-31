#!/usr/bin/env bash
# Wiring tests for the _iree_* stage helpers of build-app-wheelhouse.sh: the
# dynamic-scope couplings a refactor can sever. docs/cross-build-verification.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

WHEELHOUSE_SH="${TESTS_DIR}/../05-frameworks/torch/build-app-wheelhouse.sh"

# ── extract the IREE helper block + build_iree_wheels ────────────────────────
_iree_block="$(awk '
  /^_iree_check_prereqs\(\) \{$/ { f = 1 }
  f                              { print }
  /^build_iree_wheels\(\) \{$/   { g = 1 }
  g && /^\}$/                    { exit }
' "${WHEELHOUSE_SH}")"
t_case "helper block extraction"
t_assert_contains "${_iree_block}" "build_iree_wheels() {" "build_iree_wheels not in extracted block"
t_assert_contains "${_iree_block}" "_iree_package_wheels() {" "_iree_package_wheels not in extracted block"
eval "${_iree_block}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/empty" "${TMP}/nocmake"

# ── stub executables (cmake is invoked via `env`, so it must be a real file) ──
cat > "${TMP}/bin/cmake" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CMAKE_LOG}"
# Fault injection: STUB_CMAKE_FAIL is an ERE matched against the whole argv.
# `-e` is REQUIRED (grep is ugrep here); see docs/failure-modes.md
if [ -n "${STUB_CMAKE_FAIL:-}" ] && printf '%s' "$*" | grep -qE -e "${STUB_CMAKE_FAIL}"; then
  exit 7
fi
mode=configure; build_dir=""; prefix=""; want_install=0
prev=""
for a in "$@"; do
  case "${a}" in
    --build) mode=build ;;
    install) [ "${prev}" = "--target" ] && want_install=1 ;;
    -DCMAKE_INSTALL_PREFIX=*) prefix="${a#-DCMAKE_INSTALL_PREFIX=}" ;;
  esac
  case "${prev}" in
    -B|--build) build_dir="${a}" ;;
  esac
  prev="${a}"
done
if [ "${mode}" = configure ] && [ -n "${build_dir}" ]; then
  mkdir -p "${build_dir}/runtime" "${build_dir}/compiler"
fi
if [ "${want_install}" = 1 ] && [ -n "${STUB_HOST_INSTALL:-}" ]; then
  mkdir -p "${STUB_HOST_INSTALL}/bin"
  for t in iree-c-embed-data iree-flatcc-cli iree-tblgen; do
    printf '#!/bin/sh\n' > "${STUB_HOST_INSTALL}/bin/${t}"; chmod +x "${STUB_HOST_INSTALL}/bin/${t}"
  done
fi
exit 0
EOS
cat > "${TMP}/bin/ninja" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
cat > "${TMP}/bin/ccache" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  -p) printf 'max_size = %s\n' "${CCACHE_MAXSIZE:-unset}" ;;
esac
exit 0
EOS
cat > "${TMP}/bin/git" <<'EOS'
#!/usr/bin/env bash
[ "${STUB_GIT_FAIL:-0}" = "1" ] && exit 1
if [ "${1:-}" = "clone" ]; then
  dest="${!#}"
  mkdir -p "${dest}/runtime" "${dest}/compiler"
  for p in runtime compiler; do
    printf '_is_abi3_build = sys.version_info >= (3, 12) and not Py_GIL_DISABLED\n' \
      > "${dest}/${p}/setup.py"
  done
fi
exit 0
EOS
cat > "${TMP}/bin/fakepython" <<'EOS'
#!/usr/bin/env bash
# only ever called as: -m pip wheel <project> -w <dist> --no-deps ...
# Recorded: packaging is the only caller, so an empty log proves it never ran.
[ -n "${STUB_PY_LOG:-}" ] && printf '%s\n' "$*" >> "${STUB_PY_LOG}"
proj=""; dist=""; prev=""
for a in "$@"; do
  case "${prev}" in wheel) proj="${a}" ;; -w) dist="${a}" ;; esac
  prev="${a}"
done
[ -n "${dist}" ] && mkdir -p "${dist}" && \
  : > "${dist}/iree_base_$(basename "${proj}")-3.11.0-cp314-cp314-linux_riscv64.whl"
exit 0
EOS
chmod +x "${TMP}/bin/"*
PATH="${TMP}/bin:${PATH}"
export PATH
cp "${TMP}/bin/git" "${TMP}/bin/ninja" "${TMP}/nocmake/" 2>/dev/null || true

# ── stubbed shell collaborators ──────────────────────────────────────────────
STUB_CROSS=0
STUB_WHEEL_PLATFORM="linux_riscv64"
STUB_LAUNCHER="ccache"
STUB_QNN=""
STUB_RETAG_LOG=""
log()  { printf 'INFO:%s\n' "$*" >&2; }
warn() { printf 'WARN:%s\n' "$*" >&2; }
wheel_platform_tag() { printf '%s' "${STUB_WHEEL_PLATFORM}"; [ -n "${STUB_WHEEL_PLATFORM}" ]; }
cross_build_is_active() { [ "${STUB_CROSS}" -eq 1 ]; }
cross_target_triplet() { printf '%s' "riscv64-linux-gnu"; }
compiler_cache_launcher() { printf '%s' "${STUB_LAUNCHER}"; }
resolve_qnn_sdk() { printf '%s' "${STUB_QNN}"; [ -n "${STUB_QNN}" ]; }
write_cross_cmake_toolchain_file() { printf '%s' "${TMP}/toolchain.cmake"; }
append_common_cross_cmake_args() { local -n _ref="$1"; _ref+=("-DSTUB_COMMON_CROSS=1"); return 0; }
resolve_target_python_sysconfig_export() {
  printf 'export _PYTHON_SYSCONFIGDATA_NAME=%s; export PYTHONPATH=%s' \
    "_sysconfigdata__linux_riscv64-linux-gnu" "${TMP}/sysconfig"
}
retag_directory_wheels() { STUB_RETAG_LOG="${STUB_RETAG_LOG}|$2:$3"; return 0; }

BUILD_PYTHON="${TMP}/bin/fakepython"
MAX_JOBS=2
IREE_REF="v3.11.0"

# Fresh sandbox per invocation; returns build_iree_wheels' status in RC.
RC=0
_run() {
  APP_WHEELHOUSE_BUILD_ROOT="${TMP}/work"
  APP_WHEELHOUSE_DIR="${TMP}/wheels"
  rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
  mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
  STUB_CMAKE_LOG="${TMP}/cmake.log"; : > "${STUB_CMAKE_LOG}"
  STUB_PY_LOG="${TMP}/py.log"; : > "${STUB_PY_LOG}"
  STUB_HOST_INSTALL="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host/install"
  STUB_RETAG_LOG=""
  export STUB_CMAKE_LOG STUB_HOST_INSTALL STUB_CMAKE_FAIL STUB_PY_LOG
  unset CCACHE_MAXSIZE SCCACHE_CACHE_SIZE _PYTHON_SYSCONFIGDATA_NAME
  RC=0
  build_iree_wheels >/dev/null 2>"${TMP}/err.log" || RC=$?
}
_wheels() { ( shopt -s nullglob; set -- "${APP_WHEELHOUSE_DIR}"/*.whl; printf '%s\n' "$#" ); }
# Number of `pip wheel` invocations, i.e. whether _iree_package_wheels ran at all.
_pkg_calls() { printf '%s\n' "$(wc -l < "${TMP}/py.log" 2>/dev/null || echo 0)"; }

# ── native lane ──────────────────────────────────────────────────────────────
STUB_CROSS=0
_run
t_case "native lane succeeds and packages both wheel projects"
t_assert_eq "0" "${RC}" "build_iree_wheels rc"
t_assert_eq "2" "$(_wheels)" "wheels copied into APP_WHEELHOUSE_DIR"
_cmake_log="$(cat "${TMP}/cmake.log")"
t_assert_contains "${_cmake_log}" "-DIREE_BUILD_COMPILER=ON" "native configure flag"
t_assert_contains "${_cmake_log}" "-DIREE_ENABLE_PYTHON_STABLE_ABI=OFF" "native abi3 flag"

t_case "compiler-cache setup reaches the native build step (dynamic scope)"
t_assert_contains "${_cmake_log}" "-DCMAKE_C_COMPILER_LAUNCHER=ccache" "ccache_cmake_args lost"
t_assert_contains "${_cmake_log}" "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "ccache_cmake_args lost"

t_case "ccache exports survive the helper boundary"
t_assert_eq "64G" "${CCACHE_MAXSIZE:-}" "CCACHE_MAXSIZE export"
t_assert_eq "1" "${CCACHE_COMPRESS:-}" "CCACHE_COMPRESS export"
t_assert_contains "${CCACHE_SLOPPINESS:-}" "pch_defines" "CCACHE_SLOPPINESS export"
t_assert_eq "ccache" "${_iree_launcher:-}" "_iree_launcher must stay non-local"

t_case "abi3 setup.py patch is applied to the fetched tree"
t_assert_contains "$(cat "${TMP}/work/iree/runtime/setup.py")" "False and " "runtime setup.py not patched"
t_assert_contains "$(cat "${TMP}/work/iree/compiler/setup.py")" "False and " "compiler setup.py not patched"

t_case "packaging retags with the wheel_platform from the prereq stage"
t_assert_contains "${STUB_RETAG_LOG}" "iree_base_runtime:linux_riscv64" "retag runtime"
t_assert_contains "${STUB_RETAG_LOG}" "iree_base_compiler:linux_riscv64" "retag compiler"

# ── native lane, sccache launcher ────────────────────────────────────────────
STUB_LAUNCHER="/usr/bin/sccache"
_run
t_case "sccache cap + log env are exported for the build steps"
t_assert_eq "0" "${RC}" "build_iree_wheels rc"
t_assert_eq "64G" "${SCCACHE_CACHE_SIZE:-}" "SCCACHE_CACHE_SIZE export"
t_assert_contains "$(cat "${TMP}/cmake.log")" "-DCMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache" "launcher"
STUB_LAUNCHER="ccache"

# ── cross lane ───────────────────────────────────────────────────────────────
STUB_CROSS=1
_run
_cmake_log="$(cat "${TMP}/cmake.log")"
t_case "cross lane runs the host stage then the target stage"
t_assert_eq "0" "${RC}" "build_iree_wheels rc"
t_assert_contains "${_cmake_log}" "-DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_PYTHON_BINDINGS=OFF" "host stage probes COMPILER=OFF first"
t_assert_contains "${_cmake_log}" "-DIREE_HOST_BIN_DIR=${TMP}/work/iree-build-host/install/bin" "target uses host tools"
t_assert_contains "${_cmake_log}" "-DCMAKE_TOOLCHAIN_FILE=${TMP}/toolchain.cmake" "toolchain file"
t_assert_contains "${_cmake_log}" "-DLLVM_HOST_TRIPLE=riscv64-linux-gnu" "target triple pin"

t_case "cmake_args reach the target configure, and carry NO QNN flag"
t_assert_contains "${_cmake_log}" "-DSTUB_COMMON_CROSS=1" "append_common_cross_cmake_args lost"
# IREE has no Qualcomm backend; -DIREE_TARGET_BACKEND_QNN never existed.
t_assert_fails grep -q "QNN" "${TMP}/cmake.log"

t_case "the NATIVE sub-build pin carries host compilers + the cache launcher"
t_assert_contains "${_cmake_log}" "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=" "CROSS_TOOLCHAIN_FLAGS_NATIVE lost"
t_assert_contains "${_cmake_log}" ";-DCMAKE_C_COMPILER_LAUNCHER=ccache;-DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "_iree_launcher lost in native_flags"

t_case "cross target is runtime-only, and that reaches the packaging step"
t_assert_eq "1" "$(_wheels)" "cross must ship exactly the runtime wheel"
t_assert_contains "${STUB_RETAG_LOG}" "iree_base_runtime:linux_riscv64" "retag runtime"
t_assert_eq "" "${STUB_RETAG_LOG##*iree_base_runtime:linux_riscv64}" "compiler wheel must not be packaged on cross"

t_case "target python sysconfig export survives into the wheel-packing step"
t_assert_eq "_sysconfigdata__linux_riscv64-linux-gnu" "${_PYTHON_SYSCONFIGDATA_NAME:-}" "sysconfig export lost"

t_case "a staged QNN SDK still emits no QNN flags"
STUB_QNN="${TMP}/qairt"
_run
t_assert_eq "0" "${RC}" "build_iree_wheels rc"
t_assert_contains "$(cat "${TMP}/cmake.log")" "-DSTUB_COMMON_CROSS=1" "configure did not run"
t_assert_fails grep -q "QNN" "${TMP}/cmake.log"
STUB_QNN=""

# ── skip / failure paths: each must return 1 FROM build_iree_wheels ──────────
t_case "missing cmake skips IREE with rc=1"
APP_WHEELHOUSE_BUILD_ROOT="${TMP}/work"; APP_WHEELHOUSE_DIR="${TMP}/wheels"
_rc=0; ( PATH="${TMP}/nocmake:/usr/bin:/bin"; build_iree_wheels ) >/dev/null 2>&1 || _rc=$?
t_assert_eq "1" "${_rc}" "prereq failure must return 1"

t_case "missing wheel platform tag skips IREE with rc=1"
STUB_WHEEL_PLATFORM=""
_run
t_assert_eq "1" "${RC}" "wheel-platform failure must return 1"
STUB_WHEEL_PLATFORM="linux_riscv64"

t_case "clone failure skips IREE with rc=1"
STUB_GIT_FAIL=1; export STUB_GIT_FAIL
_run
t_assert_eq "1" "${RC}" "clone failure must return 1"
t_assert_eq "0" "$(_wheels)" "no wheels on a failed clone"
STUB_GIT_FAIL=0; export STUB_GIT_FAIL

# Build-stage failures, mutation-covering `|| return 1` at all five call sites.
# rc alone does not discriminate, so assert the packaging diagnostic is ABSENT
# too — docs/cross-build-verification.md
_no_packaging_diag() { t_assert_fails grep -qF -e "wheel project" "${TMP}/err.log"; }
export STUB_CMAKE_FAIL=""

t_case "host-stage build failure returns 1 from build_iree_wheels (cross lane)"
STUB_CROSS=1
STUB_CMAKE_FAIL='--build .*iree-build-host --target install'
_run
t_assert_eq "1" "${RC}" "_iree_build_host_stage failure must return 1"
t_assert_eq "0" "$(_wheels)" "no wheels when the host stage fails"
t_assert_eq "0" "$(_pkg_calls)" "packaging must not run after _iree_build_host_stage fails"
_no_packaging_diag

t_case "cross target configure failure returns 1 from build_iree_wheels"
STUB_CMAKE_FAIL='-B [^ ]*iree-build-target'
_run
t_assert_eq "1" "${RC}" "_iree_build_target_cross failure must return 1"
t_assert_eq "0" "$(_wheels)" "no wheels when the cross target build fails"
t_assert_eq "0" "$(_pkg_calls)" "packaging must not run after _iree_build_target_cross fails"
_no_packaging_diag

t_case "native target configure failure returns 1 from build_iree_wheels"
STUB_CROSS=0
STUB_CMAKE_FAIL='-B [^ ]*iree-build-target'
_run
t_assert_eq "1" "${RC}" "_iree_build_target_native failure must return 1"
t_assert_eq "0" "$(_wheels)" "no wheels when the native target build fails"
t_assert_eq "0" "$(_pkg_calls)" "packaging must not run after _iree_build_target_native fails"
_no_packaging_diag

STUB_CMAKE_FAIL=""

t_case "a failed lane does not abort the caller"
_run
t_assert_eq "0" "${RC}" "the run after a failure must still succeed"

t_summary
