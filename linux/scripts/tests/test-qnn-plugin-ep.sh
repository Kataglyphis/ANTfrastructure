#!/usr/bin/env bash
# 36-build-qnn-plugin-ep.sh's pins, configure retries, skip tree, ORT home shim, library verdict, the verify stages, the census root and the Dockerfile wiring; no download, no compiler, no device.
set -u
EP_SCRIPT=36-build-qnn-plugin-ep.sh
# shellcheck source=linux/scripts/tests/plugin-ep-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/plugin-ep-fixture.sh"
BUILD="${TESTS_DIR}/../03-media/build/onnxruntime/build"
DF="${TESTS_DIR}/../../Dockerfile.media"

t_case "the plugin comes from the pinned fork tag, never a prebuilt wheel or archive"
t_assert_eq "https://github.com/onnxruntime/onnxruntime-qnn/archive/refs/tags/v2.7.0.tar.gz" "$(qnnep_source_url 2.7.0)"
t_assert_ok test -n "${ORT_QNN_EP_VERSION:-}"
t_assert_ok grep -qE '^[0-9a-f]{64}$' <<< "${ORT_QNN_EP_SOURCE_SHA256:-}"
t_assert_eq 0 "$(grep -cE 'releases/download|\.whl|\.tgz|pypi' "${EP}" || true)" "no release asset, wheel or tarball download in the build script"
t_assert_contains "$(cat "${EP}")" 'HOST_PYTHON_BIN}" -S "${QNNEP_SRC}/tools/ci_build/build.py"' "a site-less Python keeps the fork's torch-gated import off"

t_case "configure retries preserve argv, every attempt and raw exhaustion; compilation itself runs once"
cat > "${_T}/qnn fake python" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
case "${!#}" in
  --update)
    printf 'update\n' >> "${QNN_FIXTURE_RUN}/updates"
    attempt="$(wc -l < "${QNN_FIXTURE_RUN}/updates")"
    printf '%s\0' "$@" > "${QNN_FIXTURE_RUN}/update-argv"
    printf 'configure attempt %s\n' "${attempt}"
    printf 'fetch diagnostic %s\n' "${attempt}" >&2
    if [ "${attempt}" -le "${QNN_FIXTURE_FAIL_UNTIL}" ]; then exit "${QNN_FIXTURE_STATUS}"; fi
    ;;
  --build)
    printf 'build\n' >> "${QNN_FIXTURE_RUN}/builds"
    printf 'build invocation\n'
    exit "${QNN_FIXTURE_BUILD_STATUS}"
    ;;
  *) exit 99 ;;
esac
exit 0
PYTHON
chmod +x "${_T}/qnn fake python"
_qnnep_compile_fixture() (
  set -euo pipefail
  source "${TESTS_DIR}/../01-core/logging.sh"
  export QNN_FIXTURE_RUN="$1" QNN_FIXTURE_FAIL_UNTIL="$2" QNN_FIXTURE_STATUS=37 QNN_FIXTURE_BUILD_STATUS="$3"
  sleep() { printf '%s\n' "$1" >> "${QNN_FIXTURE_RUN}/sleeps"; }
  setup_linux_cross_env() { :; }
  setup_host_python_environment() { :; }
  cross_build_is_active() { return 1; }
  append_onnx_ccache_build_args() { :; }
  qnnep_ort_home_headers() { printf 'headers\n' >> "${QNN_FIXTURE_RUN}/headers"; printf '3'; }
  cmake_assert_compiler_cache_pin() { printf 'checked\n' >> "${QNN_FIXTURE_RUN}/finalized"; }
  plugin_ep_built_module() { printf 'module.so'; }
  qnnep_assert_no_foreign_core() { :; }
  export HOST_PYTHON_BIN="${_T}/qnn fake python"
  export QNNEP_WORK_DIR="$1" QNNEP_SRC="$1/source path" QNNEP_QAIRT="$1/qairt path"
  export QNNEP_ORT_HOME="$1/ort home" QNNEP_ORT_DIR="$1/ort prefix"
  export QNNEP_VERSION=2.7.0 JOBS=2 QNN_SDK_LINUX_LIBDIR=aarch64-oe-linux-gcc11.2
  mkdir -p "${QNNEP_WORK_DIR}"
  qnnep_compile
)
while read -r _fail_until _expected_updates _expected_sleeps; do
  _run="${_T}/configure ${_fail_until}"
  _out="$(_qnnep_compile_fixture "${_run}" "${_fail_until}" 0 2>&1)"; _rc=$?
  t_assert_eq 0 "${_rc}" "${_out}"
  t_assert_eq "${_expected_updates}" "$(wc -l < "${_run}/updates")"
  t_assert_eq 1 "$(wc -l < "${_run}/builds")" "compile runs once after successful configure"
  t_assert_ok test -f "${_run}/finalized"
  _sleep_count=0
  [ ! -f "${_run}/sleeps" ] || _sleep_count="$(wc -l < "${_run}/sleeps")"
  t_assert_eq "${_expected_sleeps}" "${_sleep_count}"
  t_assert_contains "$(cat "${_run}/build.log")" 'configure attempt 1' "first attempt survives successful compile"
  t_assert_contains "$(cat "${_run}/build.log")" "fetch diagnostic ${_expected_updates}" "stderr survives tee"
  t_assert_contains "$(cat "${_run}/build.log")" 'build invocation'
  mapfile -d '' -t _qnn_argv < "${_run}/update-argv"
  t_assert_eq '-S' "${_qnn_argv[0]}"
  t_assert_eq "${_run}/source path/tools/ci_build/build.py" "${_qnn_argv[1]}"
  _qnn_home_arg='not found'
  for ((_i = 0; _i < ${#_qnn_argv[@]} - 1; _i++)); do
    [ "${_qnn_argv[_i]}" != --qnn_home ] || _qnn_home_arg="${_qnn_argv[_i + 1]}"
  done
  t_assert_eq "${_run}/qairt path" "${_qnn_home_arg}" "retry preserves argument boundaries"
done <<'CASES'
0 1 0
1 2 1
2 3 2
CASES
_run="${_T}/configure exhausted"
_out="$(_qnnep_compile_fixture "${_run}" 99 0 2>&1)"; _rc=$?
t_assert_eq 37 "${_rc}" "exhaustion retains the configure command's raw failure"
t_assert_eq 3 "$(wc -l < "${_run}/updates")"
t_assert_eq $'10\n10' "$(cat "${_run}/sleeps")" "bounded attempts retain the shared delay"
t_assert_fails test -e "${_run}/headers"
t_assert_fails test -e "${_run}/builds"
t_assert_fails test -e "${_run}/finalized"
t_assert_contains "$(cat "${_run}/build.log")" 'fetch diagnostic 1'
t_assert_contains "$(cat "${_run}/build.log")" 'fetch diagnostic 3'
_run="${_T}/compile failure"
_out="$(_qnnep_compile_fixture "${_run}" 0 29 2>&1)"; _rc=$?
t_assert_eq 29 "${_rc}" "a compile failure remains raw and is not retried"
t_assert_eq 1 "$(wc -l < "${_run}/updates")"
t_assert_eq 1 "$(wc -l < "${_run}/builds")"
t_assert_fails test -e "${_run}/sleeps"
t_assert_fails test -e "${_run}/finalized"
t_assert_contains "$(cat "${_run}/build.log")" 'configure attempt 1'
t_assert_contains "$(cat "${_run}/build.log")" 'build invocation'

t_case "off arm64 the build step only leaves the empty output tree the media merge COPYs"
t_assert_eq "Skipping the QNN plugin EP (arm64-only, target amd64)" "$(TARGET_ARCH=amd64 QNNEP_OUTPUT_DIR="${_T}/ph" qnnep_build 2>&1)"
t_assert_ok test -d "${_T}/ph"
t_assert_eq "" "$(ls -A "${_T}/ph")" "nothing is built"
t_assert_eq "riscv64" "$(TARGET_ARCH=riscv64 qnnep_target_arch)"

t_case "the --ort_home shim is the chain's headers and library under the names the fork's copy step expects"
for _d in fork/cmake nofork/cmake chain/lib chain/include; do mkdir -p "${_T}/${_d}"; done
printf '#c\nort_core;https://github.com/microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip;abc\n' > "${_T}/fork/cmake/deps.txt"
t_assert_eq "1.29.0" "$(qnnep_ort_core_version "${_T}/fork")"
: > "${_T}/nofork/cmake/deps.txt"
t_assert_contains "$(qnnep_ort_core_version "${_T}/nofork" 2>&1)" "names no ort_core tag"
for _f in lib/libonnxruntime.so.1.31.1 lib/libonnxruntime_providers_shared.so include/onnxruntime_c_api.h; do printf 'x' > "${_T}/chain/${_f}"; done
_h="$(qnnep_ort_home "${_T}/chain" "${_T}/home" 1.29.0)"
t_assert_eq "${_T}/home" "${_h}"
t_assert_eq "${_T}/chain/lib/libonnxruntime.so.1.31.1" "$(readlink "${_h}/lib/libonnxruntime.so.1.29.0")" "the fork's versioned name is the chain's real library"
t_assert_eq "${_T}/chain/lib/libonnxruntime.so.1.31.1" "$(readlink "${_h}/lib/libonnxruntime.so.1")"
t_assert_ok test -e "${_h}/lib/libonnxruntime_providers_shared.so"
t_assert_ok test -d "${_h}/include"
_inc="${_T}/core/include/onnxruntime/core"; mkdir -p "${_inc}/framework/sub"
for _f in session/onnxruntime_c_api.h session/onnxruntime_experimental_c_api.inc providers/cpu/cpu_provider_factory.h framework/provider_options.h; do
  mkdir -p "${_inc}/${_f%/*}"; : > "${_inc}/${_f}"
done
t_assert_eq 4 "$(qnnep_ort_home_headers "${_h}" "${_T}/core")" "every file of the three public header dirs, .inc included, nothing from deeper"
t_assert_eq "${_T}/core/include/onnxruntime/core/session/onnxruntime_experimental_c_api.inc" "$(readlink "${_h}/include/onnxruntime_experimental_c_api.inc")"
t_assert_contains "$(qnnep_ort_home_headers "${_h}" "${_T}/nocore" 2>&1)" "holds no ORT public headers"
t_assert_contains "$(cat "${EP}")" 'build.py" "${args[@]}" --update' "configure first"
t_assert_contains "$(cat "${EP}")" 'build.py" "${args[@]}" --build' "then build, after the headers are in place"
t_assert_contains "$(qnnep_ort_home "${_T}/nochain" "${_T}/home2" 1.29.0 2>&1)" "no libonnxruntime.so.N.N.N under"

t_case "copies of the chain library in the build dir pass the core check; any other libonnxruntime there fails it (the first arm64 proof chain tripped on the fork's own copies)"
mkdir -p "${_T}/bd/Release"; cp "${_T}/chain/lib/libonnxruntime.so.1.31.1" "${_T}/bd/Release/libonnxruntime.so.1.29.0"; cp "${_T}/chain/lib/libonnxruntime.so.1.31.1" "${_T}/bd/Release/libonnxruntime.so"
t_assert_ok qnnep_assert_no_foreign_core "${_T}/bd" "${_T}/chain"
printf 'other bytes' > "${_T}/bd/Release/libonnxruntime.so.1.29.0"
t_assert_contains "$(qnnep_assert_no_foreign_core "${_T}/bd" "${_T}/chain" 2>&1)" "libonnxruntime.so.1.29.0 is an ONNX Runtime core library the chain did not build"
t_assert_contains "$(qnnep_assert_no_foreign_core "${_T}/bd" "${_T}/nochain" 2>&1)" "no libonnxruntime.so.N.N.N under"

t_case "the library verdict: both exports, and every NEEDED name is the chain's, a QAIRT backend beside it or the C/C++ runtime"
mkdir -p "${_T}/bin" "${_T}/ort/lib" "${_T}/ep/lib"; : > "${_T}/ort/lib/libonnxruntime.so.1"; : > "${_T}/ep/lib/libQnnHtp.so"; printf 'x' > "${_T}/ep/lib/libonnxruntime_providers_qnn.so"
cat > "${_T}/bin/readelf" <<'READELF'
#!/usr/bin/env bash
case "$1" in
  --dyn-syms) printf '%s\n' "${FAKE_EXPORTS:-}" | tr ' ' '\n' | sed 's/^/   1: 0000 0 FUNC GLOBAL DEFAULT 1 /' ;;
  -d) printf '%s\n' "${FAKE_NEEDED:-}" | tr ' ' '\n' | sed 's/.*/ 0x0000000000000001 (NEEDED) Shared library: [&]/' ;;
esac
READELF
chmod +x "${_T}/bin/readelf"
_v() { PATH="${_T}/bin:${PATH}" QNNEP_ORT_DIR="${_T}/ort" FAKE_EXPORTS="$1" FAKE_NEEDED="$2" qnnep_verify_library "${_T}/ep/lib/libonnxruntime_providers_qnn.so" 2>&1; }
t_assert_eq "" "$(_v 'CreateEpFactories@@VERS_1.0 ReleaseEpFactory@@VERS_1.0' 'libonnxruntime.so.1 libQnnHtp.so libstdc++.so.6 libc.so.6 libm.so.6')"
t_assert_contains "$(_v 'CreateEpFactories' 'libc.so.6')" "does not export ReleaseEpFactory"
t_assert_contains "$(_v 'CreateEpFactories ReleaseEpFactory' 'libonnxruntime.so.2')" "needs libonnxruntime.so.2, which the chain prefix ${_T}/ort does not hold"
t_assert_contains "$(_v 'CreateEpFactories ReleaseEpFactory' 'libQnnGpu.so')" "needs libQnnGpu.so, not staged beside it"
t_assert_contains "$(_v 'CreateEpFactories ReleaseEpFactory' 'libprotobuf.so.32')" "needs libprotobuf.so.32, which is neither the chain, QAIRT nor the C/C++ runtime"
t_assert_contains "$(qnnep_verify_library "${_T}/absent.so" 2>&1)" "is missing"

t_case "the CPU prefix refuses an in-tree QNN provider; the plugin stage checks the tree on arm64 and skips elsewhere"
mkdir -p "${_T}/cpu/lib" "${_T}/cpu/include/onnxruntime/core/session"; printf 'x' > "${_T}/cpu/lib/libonnxruntime.so.1.31.1"; printf 'x' > "${_T}/cpu/include/onnxruntime/core/session/onnxruntime_c_api.h"
t_assert_ok bash "${VERIFY}" onnxruntime-cpu "${_T}/cpu"
printf 'x' > "${_T}/cpu/lib/libonnxruntime_providers_qnn.so"
_verify onnxruntime-cpu "${_T}/cpu"
t_assert_eq 1 "${_rc}" "an in-tree provider in the CPU prefix fails the stage"
t_assert_contains "${_out}" "libonnxruntime_providers_qnn.so in cpu: that EP ships as the plugin in /usr/local/lib/onnxruntime-ep-qnn"
mkdir -p "${_T}/qnn/lib" "${_T}/qnn/licenses/onnxruntime-qnn" "${_T}/qnn/licenses/qairt"
printf 'x' > "${_T}/qnn/lib/libonnxruntime_providers_qnn.so"; printf 'x' > "${_T}/qnn/lib/libQnnHtp.so"; printf 'v\n' > "${_T}/qnn/provenance.txt"
printf 'MIT\n' > "${_T}/qnn/licenses/onnxruntime-qnn/LICENSE"; printf 'EULA\n' > "${_T}/qnn/licenses/qairt/LICENSE.pdf"
_out="$(PATH="${_T}/bin:${PATH}" FAKE_EXPORTS='CreateEpFactories@@VERS_1.0 ReleaseEpFactory@@VERS_1.0' TARGET_ARCH=arm64 bash "${VERIFY}" onnxruntime-ep-qnn "${_T}/qnn" 2>&1)"; _rc=$?
t_assert_eq 0 "${_rc}" "${_out}"
t_assert_contains "${_out}" "plugin QNN EP exports ReleaseEpFactory"
t_assert_contains "${_out}" "QAIRT HTP backend beside the plugin"
PATH="${_T}/bin:${PATH}" FAKE_EXPORTS='CreateEpFactories' TARGET_ARCH=arm64 _verify onnxruntime-ep-qnn "${_T}/qnn"
t_assert_eq 1 "${_rc}" "a module without ReleaseEpFactory fails the stage"
mkdir -p "${_T}/empty"
TARGET_ARCH=arm64 _verify onnxruntime-ep-qnn "${_T}/empty"
t_assert_eq 1 "${_rc}" "arm64 without the plugin fails"
t_assert_contains "${_out}" "arm64 builds the plugin QNN EP, but"
TARGET_ARCH=amd64 _verify onnxruntime-ep-qnn "${_T}/empty"
t_assert_eq 0 "${_rc}" "amd64 skips"
t_assert_contains "${_out}" "SKIP [onnxruntime-ep-qnn]"

t_case "the plugin tree is a census root, the in-tree EP is gone from the ORT and GenAI builds, and the merge carries the tree"
# shellcheck source=../06-packaging/check-ort-provenance.sh
source "${TESTS_DIR}/../06-packaging/check-ort-provenance.sh"
t_assert_contains "$(ort_census_image_args | tr '\n' ' ')" "--ref /usr/local/lib/onnxruntime-ep-qnn --allow /usr/local/lib/onnxruntime-ep-qnn"
t_assert_contains "$(ort_census_chain_roots)" "${QNNEP_WORK_DIR}/seeds/onnxruntime-qnn" "the census knows where the fork source is built"
t_assert_contains "$(ort_census_chain_roots)" "${QNNEP_WORK_DIR}/build/Release/_deps/ort_core-src" "and where its ort_core headers come from"
t_assert_eq 0 "$(grep -cE 'onnxruntime_USE_QNN|QNN_HOME|stage_qnn_runtime' "${BUILD}/30-build-native.sh" || true)" "no in-tree QNN in the ORT CPU build"
t_assert_eq 0 "$(grep -cE 'stage_qnn_runtime|resolve_qnn_sdk' "${BUILD}/60-build-genai.sh" || true)" "GenAI stages no QNN of its own"
t_assert_eq 1 "$(grep -cE '^COPY --link --from=onnxruntime /usr/local/lib/onnxruntime-ep-qnn /usr/local/lib/onnxruntime-ep-qnn$' "${DF}")" "the merge stage copies the plugin tree"
t_assert_eq "    bash /opt/scripts/03-media/build/onnxruntime/build/36-build-qnn-plugin-ep.sh build; \\" "$(grep -E '36-build-qnn-plugin-ep.sh build' "${DF}")" "the call sits after the GPU if/fi, on every chain"
t_assert_eq 0 "$(sed -n '/kataglyphis.step=onnxruntime-cpu$/,/kataglyphis.step=onnxruntime-cpu-verify/p' "${DF}" | grep -c 'qnn-sdk' || true)" "the ORT CPU RUN mounts no QAIRT any more"
t_assert_contains "$(sed -n '/kataglyphis.step=onnxruntime-gpu$/,/kataglyphis.step=onnxruntime-genai$/p' "${DF}")" 'id=qnn-sdk-${TARGET_ARCH}' "the plugin RUN carries the QAIRT cache"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.package")" 'ENV ORT_QNN_EP_ROOT=${QNN_ON:+/usr/local/lib/onnxruntime-ep-qnn}' "the root is advertised through the arm64-only ARG"

t_summary
