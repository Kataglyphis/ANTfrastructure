#!/usr/bin/env bash
# The dynamic-scope couplings between build-app-wheelhouse.sh's _iree_* helpers; see docs/cross-build-verification.md#the-linuxscriptstests-suites
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
# STUB_CMAKE_FAIL_AGAIN=1 fails a call whose argv was seen before, i.e. the settling second configure.
if [ -n "${STUB_CMAKE_FAIL_AGAIN:-}" ] && [ "$(grep -cxF -e "$*" "${STUB_CMAKE_LOG}")" -ge 2 ]; then
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
abi=cp314
case "$0" in *-cp314t) abi=cp314t ;; esac
[ -n "${dist}" ] && mkdir -p "${dist}" && \
  : > "${dist}/iree_base_$(basename "${proj}")-3.11.0-cp314-${abi}-linux_riscv64.whl"
exit 0
EOS
chmod +x "${TMP}/bin/"*
cp "${TMP}/bin/fakepython" "${TMP}/bin/fakepython-cp314t"
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
# The cp314t twin helpers, honouring the real library's cross skip; the venv's python is fakepython making cp314t wheels.
STUB_FT=1
ft_twin_wanted() {
  if [ "${STUB_FT}" = 1 ] && ! cross_build_is_active; then return 0; fi
  return 1
}
ft_twin_start() {
  ft_twin_wanted "$1" || return 1
  mkdir -p "$2/bin"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${TMP}/bin/fakepython-cp314t" > "$2/bin/python"
  chmod +x "$2/bin/python"
}
ft_twin_store_built() {
  [ -z "${STUB_STORE_FAIL:-}" ] || return 1
  mkdir -p "$2"
  cp "$1"/*-cp314t-*.whl "$2/"
}

BUILD_PYTHON="${TMP}/bin/fakepython"
MAX_JOBS=2
IREE_REF="v3.11.0"
STUB_CMAKE_FAIL=""
STUB_CMAKE_FAIL_AGAIN=""

# Fresh sandbox per invocation; returns build_iree_wheels' status in RC.
RC=0
_run() {
  APP_WHEELHOUSE_BUILD_ROOT="${TMP}/work"
  APP_WHEELHOUSE_DIR="${TMP}/wheels"
  APP_WHEELHOUSE_FT_DIR="${TMP}/ft-wheels"
  rm -rf "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}" "${APP_WHEELHOUSE_FT_DIR}"
  mkdir -p "${APP_WHEELHOUSE_BUILD_ROOT}" "${APP_WHEELHOUSE_DIR}"
  STUB_CMAKE_LOG="${TMP}/cmake.log"; : > "${STUB_CMAKE_LOG}"
  STUB_PY_LOG="${TMP}/py.log"; : > "${STUB_PY_LOG}"
  STUB_HOST_INSTALL="${APP_WHEELHOUSE_BUILD_ROOT}/iree-build-host/install"
  STUB_RETAG_LOG=""
  export STUB_CMAKE_LOG STUB_HOST_INSTALL STUB_CMAKE_FAIL STUB_CMAKE_FAIL_AGAIN STUB_PY_LOG
  unset CCACHE_MAXSIZE SCCACHE_CACHE_SIZE _PYTHON_SYSCONFIGDATA_NAME
  RC=0
  build_iree_wheels >/dev/null 2>"${TMP}/err.log" || RC=$?
}
_wheels() { ( shopt -s nullglob; set -- "${APP_WHEELHOUSE_DIR}"/*.whl; printf '%s\n' "$#" ); }
_ft_wheels() { find "${APP_WHEELHOUSE_FT_DIR}" -name '*.whl' -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tr '\n' ' '; }
# Number of `pip wheel` invocations, i.e. whether _iree_package_wheels ran at all.
_pkg_calls() { printf '%s\n' "$(wc -l < "${TMP}/py.log" 2>/dev/null || echo 0)"; }
# The cmake calls on one build tree, in order: configure (-G), build (--build) or reconfigure (the twin's).
_tree_calls() {
  awk -v t="/$1 " 'index($0, t) { print ($1 == "--build" ? "build" : ($1 == "-G" ? "configure" : "reconfigure")) }' \
    "${TMP}/cmake.log" | tr '\n' ' '
}

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

t_case "the native lane builds both cp314t twins in the warm target tree, beside the unchanged GIL wheels"
t_assert_eq "iree_base_compiler-3.11.0-cp314-cp314t-linux_riscv64.whl iree_base_runtime-3.11.0-cp314-cp314t-linux_riscv64.whl " "$(_ft_wheels)"
t_assert_eq "0" "$(compgen -G "${APP_WHEELHOUSE_DIR}/*-cp314t-*" | wc -l | tr -d ' ')" "no twin in the GIL wheelhouse"
t_assert_contains "${_cmake_log}" "-S ${TMP}/work/iree -B ${TMP}/work/iree-build-target -DPython_EXECUTABLE=${TMP}/work/iree-ft-venv/bin/python -DPython3_EXECUTABLE=${TMP}/work/iree-ft-venv/bin/python" \
  "the GIL pass's tree, reconfigured onto the free-threaded venv"
t_assert_contains "${_cmake_log}" "--build ${TMP}/work/iree-build-target -- -j2" "and rebuilt there"

t_case "the target tree configures twice before the GIL build, so the GIL wheel and its twin share one settled configuration"
t_assert_eq "configure configure build reconfigure build " "$(_tree_calls iree-build-target)" "native target tree calls"
t_assert_eq "1" "$(grep -e '^-G Ninja -S [^ ]* -B [^ ]*/iree-build-target ' "${TMP}/cmake.log" | sort -u | wc -l | tr -d ' ')" \
  "the second configure repeats the first"

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
# The target imports iree-tblgen from the host, which OFF never installs; see docs/iree-two-stage-build.md
t_assert_contains "${_cmake_log}" "-DIREE_BUILD_COMPILER=ON -DIREE_BUILD_PYTHON_BINDINGS=OFF" \
  "target OFF => host stage goes straight to COMPILER=ON"
case "${_cmake_log}" in
  *"-DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_PYTHON_BINDINGS=OFF"*)
    t_assert_eq "no OFF host probe" "an OFF host probe ran" "the discarded OFF pass is back" ;;
  *) t_assert_eq "1" "1" ;;
esac
t_assert_contains "${_cmake_log}" "-DIREE_HOST_BIN_DIR=${TMP}/work/iree-build-host/install/bin" "target uses host tools"
t_assert_contains "${_cmake_log}" "-DCMAKE_TOOLCHAIN_FILE=${TMP}/toolchain.cmake" "toolchain file"
t_assert_contains "${_cmake_log}" "-DLLVM_HOST_TRIPLE=riscv64-linux-gnu" "target triple pin"

t_case "the cross target tree is settled the same way; the host stage, which ships nothing, configures once"
t_assert_eq "configure configure build " "$(_tree_calls iree-build-target)" "cross target tree calls"
t_assert_eq "configure build " "$(_tree_calls iree-build-host)" "host tree calls"

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

t_case "a cross lane builds no twin yet"
t_assert_eq "" "$(_ft_wheels)"
t_assert_eq "0" "$(grep -c -e 'iree-ft-venv' "${TMP}/cmake.log")" "no free-threaded reconfigure"

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
# nocmake/ holds only the git and ninja stubs, so no real cmake can pass the case for the wrong reason.
APP_WHEELHOUSE_BUILD_ROOT="${TMP}/work"; APP_WHEELHOUSE_DIR="${TMP}/wheels"
_rc=0; _nocmake_out="$( PATH="${TMP}/nocmake"; build_iree_wheels 2>&1 )" || _rc=$?
t_assert_eq "1" "${_rc}" "prereq failure must return 1"
t_assert_contains "${_nocmake_out}" "cmake absent" \
  "must skip because cmake is absent, not because a later stage failed"

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

# rc alone does not discriminate, so the packaging diagnostic must be absent too; see docs/cross-build-verification.md
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

t_case "a twin that fails its rebuild or its proof fails build_iree_wheels"
STUB_CMAKE_FAIL='-DPython_EXECUTABLE=[^ ]*iree-ft-venv'
_run
t_assert_eq "1" "${RC}" "a failed free-threaded reconfigure must return 1"
t_assert_contains "$(cat "${TMP}/err.log")" "IREE free-threaded rebuild failed"
STUB_CMAKE_FAIL=""
STUB_STORE_FAIL=1 _run
t_assert_eq "1" "${RC}" "an unproved twin must return 1"
t_assert_eq "" "$(_ft_wheels)" "and nothing is stored"
STUB_FT=0 _run
t_assert_eq "0" "${RC}" "a build the table gives no twin succeeds"
t_assert_eq "" "$(_ft_wheels)" "with no twin"

STUB_CMAKE_FAIL=""

t_case "a failed settling configure fails build_iree_wheels before anything is packaged, on both lanes"
STUB_CMAKE_FAIL_AGAIN=1
_run
t_assert_eq "1" "${RC}" "native: a failed second configure must return 1"
t_assert_eq "0" "$(_pkg_calls)" "native: packaging must not run"
t_assert_contains "$(cat "${TMP}/err.log")" "IREE native configure failed"
STUB_CROSS=1
_run
t_assert_eq "1" "${RC}" "cross: a failed second configure must return 1"
t_assert_eq "0" "$(_pkg_calls)" "cross: packaging must not run"
t_assert_contains "$(cat "${TMP}/err.log")" "IREE riscv64 runtime configure failed"
STUB_CMAKE_FAIL_AGAIN=""
STUB_CROSS=0

t_case "a failed lane does not abort the caller"
_run
t_assert_eq "0" "${RC}" "the run after a failure must still succeed"

t_case "cross twin: the 3.14t reconfigure moves both FindPython spellings and drops their cached results"
ft_target_env() { :; }
_ftlog="${TMP}/ft-cmake.log"; : > "${_ftlog}"
( export PATH="${TMP}/bin:${PATH}" STUB_CMAKE_LOG="${_ftlog}"
  src_dir="${TMP}/src" target_build="${TMP}/ftb" MAX_JOBS=2 \
  FT_TARGET_INCLUDE=/x/ft/include/python3.14t FT_TARGET_LIBRARY=/x/ft/lib/libpython3.14t.so \
  _iree_free_threaded_rebuild /venv/bin/python ) >/dev/null 2>&1
_cfg="$(head -1 "${_ftlog}")"
t_assert_contains "${_cfg}" "-U _Python* -U Python_NumPy* -U Python3_NumPy*" "a GIL configure's cached FindPython results must go"
t_assert_contains "${_cfg}" "-DPython_INCLUDE_DIR=/x/ft/include/python3.14t" "find_package(Python) reads Python_*, not Python3_*"
t_assert_contains "${_cfg}" "-DPython_LIBRARY=/x/ft/lib/libpython3.14t.so"
t_assert_contains "${_cfg}" "-DPython3_INCLUDE_DIR=/x/ft/include/python3.14t"

t_summary
