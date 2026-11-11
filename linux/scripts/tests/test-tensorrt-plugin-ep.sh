#!/usr/bin/env bash
# 37-build-tensorrt-plugin-ep.sh's pins, git seed gate, TensorRT home shim, library verdict, the verify stage and the Dockerfile wiring; no download, no compiler, no GPU.
set -u
EP_SCRIPT=37-build-tensorrt-plugin-ep.sh
# shellcheck source=linux/scripts/tests/plugin-ep-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/plugin-ep-fixture.sh"
BUILD="${TESTS_DIR}/../03-media/build/onnxruntime/build"
DF="${TESTS_DIR}/../../Dockerfile.media"
# The suite runs under the media scripts' IFS: a read that splits on spaces only by luck would pass here and fail in the RUN.
IFS=$'\n\t'

# CMakeLists.txt of onnxruntime-ep-tensorrt at 6403f3ce (2026-11-07), recorded: four git dependencies plus googletest under the tests option.
cp "${TESTS_DIR}/fixtures/onnxruntime-ep-tensorrt-CMakeLists.txt" "${_T}/CMakeLists.txt"
trtep_declared_git "${_T}/CMakeLists.txt" > "${_T}/declared.txt"

t_case "the parser reads every git declaration: lower-cased name, repository and tag verbatim"
t_assert_eq 5 "$(wc -l < "${_T}/declared.txt")"
t_assert_eq "gsl https://github.com/microsoft/GSL.git v4.0.0" "$(grep '^gsl ' "${_T}/declared.txt")" "the name is lower-cased, the repository keeps its case"
t_assert_eq "onnx https://github.com/onnx/onnx.git e709452ef2bbc1d113faf678c24e6d3467696e83" "$(grep '^onnx ' "${_T}/declared.txt")" "a commit tag is read as-is"
printf 'FetchContent_Declare(\n  thing\n  URL https://example.invalid/thing.zip)\n' > "${_T}/url.txt"
t_assert_eq "" "$(trtep_declared_git "${_T}/url.txt")" "a URL declaration is not a git one"

t_case "versions.env's pins seed exactly the repositories and tags upstream declares (the Linux twin of Assert-FetchContentSeeded)"
trtep_seed_rows > "${_T}/rows.txt" || t_fail "a pin is unset or odd"
t_assert_eq 4 "$(wc -l < "${_T}/rows.txt")"
t_assert_eq 4 "$(cut -d' ' -f4 "${_T}/rows.txt" | grep -cE '^https://github\.com/[^ ]+\.tar\.gz$')" "every seed is a release archive"
t_assert_eq 4 "$(cut -d' ' -f5 "${_T}/rows.txt" | grep -cE '^[0-9a-f]{64}$')" "every seed is hash-pinned"
cut -d' ' -f1-3 "${_T}/rows.txt" > "${_T}/seeded.txt"
t_assert_ok plugin_ep_assert_seeded "${_T}/declared.txt" "${_T}/seeded.txt" "googletest"
t_assert_contains "$(plugin_ep_assert_seeded "${_T}/declared.txt" "${_T}/seeded.txt" "" 2>&1)" "googletest (https://github.com/google/googletest.git v1.14.0) has no hash-pinned seed" \
  "the inactive list is the only reason a declaration may go unseeded"
t_assert_contains "$(ORT_TENSORRT_EP_GSL_SHA256=short trtep_seed_rows 2>&1)" "is not a 64-hex sha256" "an odd pin stops the rows before any fetch"

t_case "a re-tagged git declaration is refused by name through the shared seed gate (the MIGraphX suite holds the URL cases)"
sed 's/^gsl .*/gsl https:\/\/github.com\/microsoft\/GSL.git v4.1.0/' "${_T}/seeded.txt" > "${_T}/drift.txt"
t_assert_contains "$(plugin_ep_assert_seeded "${_T}/declared.txt" "${_T}/drift.txt" googletest 2>&1)" "gsl is declared as https://github.com/microsoft/GSL.git v4.0.0 but the seed pins https://github.com/microsoft/GSL.git v4.1.0"

t_case "the TensorRT home shim links the headers and the three runtime libraries of TENSORRT_VERSION's major, or names what is missing"
_r="${_T}/root"; mkdir -p "${_r}/include" "${_r}/lib"
: > "${_r}/include/NvInfer.h"
for n in libnvinfer libnvinfer_plugin libnvonnxparser; do : > "${_r}/lib/${n}.so.11"; done
_home="$(TRTEP_WORK_DIR="${_T}/w" TENSORRT_VERSION=11.4.0.106 TENSORRT_HOME="${_r}" trtep_tensorrt_home)"
t_assert_eq "${_T}/w/tensorrt" "${_home}"
t_assert_eq "${_r}/include" "$(readlink -f "${_home}/include")"
t_assert_eq "${_r}/lib/libnvonnxparser.so.11" "$(readlink -f "${_home}/libnvonnxparser.so.11")" "the libraries sit directly in TENSORRT_HOME, as the plugin's CMake wants"
rm -f "${_r}/lib/libnvinfer_plugin.so.11"
t_assert_contains "$(TRTEP_WORK_DIR="${_T}/w2" TENSORRT_VERSION=11.4.0.106 TENSORRT_HOME="${_r}" trtep_tensorrt_home 2>&1)" "no libnvinfer_plugin.so.11 under any of:"
t_assert_contains "$(TRTEP_WORK_DIR="${_T}/w3" TENSORRT_VERSION='' TENSORRT_HOME="${_r}" trtep_tensorrt_home 2>&1)" "TENSORRT_VERSION is not set"
# A CUDA cross target hands the plugin the target's TensorRT root; a native build keeps TENSORRT_HOME (the arm64 nvidia lane, unproven by a build yet).
_trtep_cross_env_fixture() {
  bash -c '
    source "$1"
    mode="$2"; calls=""; CXX=/host/g++; CUDAHOSTCXX=/host/g++; TENSORRT_HOME=/host
    cuda_cross_active() { [ "${mode}" != native ]; }
    setup_linux_cross_env() {
      calls="${calls}setup "
      [ "${mode}" != fail ] || return 37
      CXX=/target/aarch64-linux-gnu-g++
    }
    cuda_cross_load() {
      calls="${calls}cuda "
      CUDAHOSTCXX="${CXX}"; CUDA_CROSS_TENSORRT_HOME=/target/tensorrt
    }
    if trtep_enter_cross_env; then rc=0; else rc=$?; fi
    printf "%s|%s|%s|%s|%s" "${rc}" "${CXX}" "${CUDAHOSTCXX}" "${TENSORRT_HOME}" "${calls}"
  ' _ "${EP}" "$1"
}
t_assert_eq '0|/target/aarch64-linux-gnu-g++|/target/aarch64-linux-gnu-g++|/target/tensorrt|setup cuda ' "$(_trtep_cross_env_fixture cross)" "select the target C++ compiler before CUDAHOSTCXX is published"
t_assert_eq '0|/host/g++|/host/g++|/host|' "$(_trtep_cross_env_fixture native)" "a native build keeps its compiler and TensorRT root without callbacks"
t_assert_eq '37|/host/g++|/host/g++|/host|setup ' "$(_trtep_cross_env_fixture fail)" "a failed target setup retains raw status and stops before CUDA publication"
t_assert_contains "$(t_fn_src "${EP}" trtep_compile)" 'trtep_enter_cross_env' "the compile enters the cross environment before it links the TensorRT tree"
# The header discovery itself (TENSORRT_HOME first, then first_match_using over /usr/include and /usr/local) is the ORT subject of header_discovery_tests.py.
t_assert_eq "${_r}/include/NvInfer.h" "$(TENSORRT_HOME="${_r}" trtep_tensorrt_header)"
t_assert_contains "$(TENSORRT_HOME="${_T}/nowhere" bash -c 'source "$1"; unset -f first_match_using 2>/dev/null; trtep_tensorrt_header' _ "${EP}" 2>&1)" "requires first_match_using from guard-helpers.sh"

t_case "the library verdict wants both plugin exports, a resolvable closure and a link against TensorRT's major"
t_assert_contains "$(trtep_verify_library "${_T}/absent.so" 2>&1)" "is missing"
_so="${_T}/fake.so"
printf 'not an elf' > "${_so}"
t_assert_contains "$(TENSORRT_VERSION=11.4.0.106 trtep_verify_library "${_so}" 2>&1)" "does not export CreateEpFactories"
t_assert_contains "$(TENSORRT_VERSION=11.4.0.106 trtep_verify_library "${_so}" 2>&1)" "does not link libnvinfer.so.11"
t_assert_contains "$(TENSORRT_VERSION='' trtep_verify_library "${_so}" 2>&1)" "does not link libnvinfer.so.N" "a bare verify call without TENSORRT_VERSION accepts any major"

t_case "outside an nvidia build with TensorRT the build step only leaves the empty output tree the media merge COPYs"
t_assert_eq "Skipping the TensorRT plugin EP (ENABLE_NVIDIA=false, ENABLE_TENSORRT=true)" "$(TRTEP_OUTPUT_DIR="${_T}/placeholder" ENABLE_NVIDIA=false trtep_build 2>&1)"
t_assert_eq "Skipping the TensorRT plugin EP (ENABLE_NVIDIA=true, ENABLE_TENSORRT=false)" "$(TRTEP_OUTPUT_DIR="${_T}/placeholder" ENABLE_NVIDIA=true ENABLE_TENSORRT=false trtep_build 2>&1)" "a Jetson image (CUDA without TensorRT) builds none"
t_assert_ok test -d "${_T}/placeholder"
t_assert_eq "" "$(ls -A "${_T}/placeholder")" "nothing is built"

t_case "the verify stage: skipped where no plugin is expected, fatal where one is"
set +e
ENABLE_NVIDIA=false _verify onnxruntime-ep-tensorrt "${_T}/placeholder"
t_assert_eq 0 "${_rc}"; t_assert_contains "${_out}" "SKIP [onnxruntime-ep-tensorrt]"
ENABLE_NVIDIA=true ENABLE_TENSORRT=true _verify onnxruntime-ep-tensorrt "${_T}/placeholder"
t_assert_eq 1 "${_rc}" "an nvidia image with TensorRT and no plugin fails"
t_assert_contains "${_out}" "libonnxruntime_ep_tensorrt.so"
mkdir -p "${_T}/gpu/lib"; printf 'x' > "${_T}/gpu/lib/libonnxruntime_providers_cuda.so"; printf 'x' > "${_T}/gpu/lib/libonnxruntime_providers_tensorrt.so"
ENABLE_NVIDIA=true _verify onnxruntime-gpu "${_T}/gpu"
t_assert_eq 1 "${_rc}" "an in-tree TensorRT EP in the GPU prefix fails the GPU stage"
t_assert_contains "${_out}" "libonnxruntime_providers_tensorrt.so in gpu: that EP ships as the plugin in /usr/local/lib/onnxruntime-ep-tensorrt"
t_assert_contains "${_out}" "CUDA plugin EP does not export CreateEpFactories" "and the CUDA module must be the plugin"
# ORT 1.31.1's in-tree CUDA module exports CreateEpFactories and ReleaseEpFactory too; only its GetProvider bridge tells it from the plugin (the nvidia android image, 2026-11-08).
rm -f "${_T}/gpu/lib/libonnxruntime_providers_tensorrt.so"
mkdir -p "${_T}/legacy-bin"
cat > "${_T}/legacy-bin/readelf" <<'SH'
#!/usr/bin/env bash
printf '   1: 0 0 FUNC GLOBAL DEFAULT 17 ReleaseEpFactory@@VERS_1.0\n   2: 0 0 FUNC GLOBAL DEFAULT 17 CreateEpFactories@@VERS_1.0\n   3: 0 0 FUNC GLOBAL DEFAULT 17 GetProvider@@VERS_1.0\n'
SH
chmod +x "${_T}/legacy-bin/readelf"
PATH="${_T}/legacy-bin:${PATH}" ENABLE_NVIDIA=true _verify onnxruntime-gpu "${_T}/gpu"
t_assert_eq 1 "${_rc}" "a module with both plugin exports AND GetProvider is the legacy in-tree EP"
t_assert_contains "${_out}" "CUDA plugin EP exports the legacy GetProvider bridge"
ENABLE_AMD=true _verify onnxruntime-gpu "${_T}/nogpu"
t_assert_eq 0 "${_rc}" "a rocm image has no GPU ORT build to verify"
t_assert_contains "${_out}" "the rocm variant's GPU EP is the plugin MIGraphX EP"
set -e

t_case "the verify stage's export check survives a module with thousands of dynamic symbols under pipefail"
mkdir -p "${_T}/bin" "${_T}/big/lib" "${_T}/big/licenses/x"; printf 'x' > "${_T}/big/lib/libonnxruntime_ep_tensorrt.so"; printf 'p\n' > "${_T}/big/provenance.txt"; printf 'l' > "${_T}/big/licenses/x/LICENSE"
mkdir -p "${_T}/big/licenses/protobuf"; printf 'l' > "${_T}/big/licenses/protobuf/LICENSE"
printf '#!/usr/bin/env bash\nprintf "   2: 0 0 FUNC GLOBAL DEFAULT 11 CreateEpFactories\\n"; seq 1 200000 | sed "s/^/   1: 0 0 FUNC GLOBAL DEFAULT 11 sym/"; printf "   3: 0 0 FUNC GLOBAL DEFAULT 11 ReleaseEpFactory\\n"\n' > "${_T}/bin/readelf"
chmod +x "${_T}/bin/readelf"
set +e
PATH="${_T}/bin:${PATH}" ENABLE_NVIDIA=true ENABLE_TENSORRT=true _verify onnxruntime-ep-tensorrt "${_T}/big"
set -e
t_assert_eq 0 "${_rc}" "${_out}"
t_assert_contains "${_out}" "plugin TensorRT EP exports ReleaseEpFactory"

t_case "the CUDA EP is built as the plugin, with no in-tree TensorRT beside it, and the build asserts the module's exports"
_nv="$(cat "${BUILD}/30-build-native-nvidia.sh")"
t_assert_contains "${_nv}" "--cmake_extra_defines onnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON"
t_assert_eq 0 "$(grep -cE -e '--use_tensorrt|--tensorrt_home|_ORT_USE_TENSORRT' "${BUILD}/30-build-native-nvidia.sh" || true)" "no in-tree TensorRT EP"
t_assert_contains "${_nv}" 'assert_onnx_cuda_plugin_ep "${NATIVE_GPU_OUTPUT_DIR}"'
mkdir -p "${_T}/legacy/lib"; printf 'x' > "${_T}/legacy/lib/libonnxruntime_providers_cuda.so"
# A legacy module exports the GetProvider bridge and neither plugin entry point; a presence check alone would wave it through.
_cuda_assert() { bash -c 'set -u; err() { echo "ERR $*"; exit 1; }; info() { echo "INFO $*"; }; readelf() { printf "   1: 0 0 FUNC GLOBAL DEFAULT 11 %s\n" '"$1"'; }'$'\n'"$(t_fn_src "${BUILD}/30-build-native-nvidia.sh" assert_onnx_cuda_plugin_ep)"$'\nassert_onnx_cuda_plugin_ep "$1"' _ "${_T}/legacy" 2>&1; }
t_assert_contains "$(_cuda_assert GetProvider)" "exports 'GetProvider ', not the plugin EP's two entry points" "the legacy bridge fails the build"
t_assert_contains "$(_cuda_assert ReleaseEpFactory)" "exports 'ReleaseEpFactory ', not the plugin EP's two entry points" "one entry point is not enough"
t_assert_contains "$(bash -c 'set -u; err() { echo "ERR $*"; exit 1; }; info() { echo "INFO $*"; }; readelf() { printf "   1: 0 0 FUNC GLOBAL DEFAULT 11 CreateEpFactories\n   2: 0 0 FUNC GLOBAL DEFAULT 11 ReleaseEpFactory\n"; }'$'\n'"$(t_fn_src "${BUILD}/30-build-native-nvidia.sh" assert_onnx_cuda_plugin_ep)"$'\nassert_onnx_cuda_plugin_ep "$1"' _ "${_T}/legacy" 2>&1)" \
  "INFO CUDA EP is the plugin EP" "both entry points and no bridge pass"
t_assert_eq 0 "$(ls "${BUILD}"/30-build-native-amd.sh "${TESTS_DIR}"/../patches/onnxruntime/00[34]-migraphx-*.patch 2>/dev/null | wc -l)" "the in-tree MIGraphX build and its two patches are gone"
t_assert_contains "$(cat "${BUILD}/build-onnxruntime.sh")" "the rocm variant's GPU EP is the plugin MIGraphX EP"

t_case "the plugin reaches the merged media image and the wrapper advertises its root (mutation)"
t_assert_eq 1 "$(grep -cE '^COPY --link --from=onnxruntime /usr/local/lib/onnxruntime-ep-tensorrt /usr/local/lib/onnxruntime-ep-tensorrt$' "${DF}")" "the merge stage copies the plugin tree"
t_assert_contains "$(grep -E '37-build-tensorrt-plugin-ep.sh build' "${DF}")" "verify-media-artifacts.sh onnxruntime-ep-tensorrt" "the build and its verify stage run in the GPU RUN, on every chain"
t_assert_eq 0 "$(grep -cE 'ENABLE_AMD.*--step gpu|--step gpu.*ENABLE_AMD' "${DF}" || true)" "the GPU ORT build runs for nvidia alone"
t_assert_contains "$(cat "${TESTS_DIR}/../../Dockerfile.package")" 'ENV ORT_TENSORRT_EP_ROOT=${TRT_ON:+/usr/local/lib/onnxruntime-ep-tensorrt}' "the root follows ENABLE_TENSORRT"
# shellcheck source=../06-packaging/check-ort-provenance.sh
source "${TESTS_DIR}/../06-packaging/check-ort-provenance.sh"
t_assert_contains "$(ort_census_contract)" "tensorrt-ep|libonnxruntime_ep_tensorrt.so|/usr/local/lib/onnxruntime-ep-tensorrt/ort-provenance/tensorrt-ep.json" "the census knows the plugin as a consumer"

t_summary
