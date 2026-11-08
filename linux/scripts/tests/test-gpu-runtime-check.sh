#!/usr/bin/env bash
# check-gpu-runtime.sh's verdicts over recorded probes: the published :latest-rocm of 2026-10-09 fails, the fixed one passes.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../06-packaging/check-gpu-runtime.sh"

SDK=/opt/venv/lib/python3.14/site-packages/_rocm_sdk_core
# The published :latest-rocm (2026-10-09), probed on 2026-10-21.
ROCM_SHIPPED="GPUR ENABLE false true false
GPUR ROCM_PATH <unset>
GPUR HIP_PATH <unset>
GPUR PATHROCM no
GPUR ROCMDIR /opt/rocm
GPUR HIPVERSION 7.16.26385-0000000
GPUR HIPROCMPATH ${SDK}
GPUR HIPCLANG ${SDK}/lib/llvm/bin
GPUR HIPCC fail ld.lld: error: cannot open ${SDK}/lib/libamdhip64.so: No such file or directory
GPUR MGXEP_ROOT <unset>
GPUR MGXEP_SO <absent>
GPUR ORTEP MIGraphXExecutionProvider,WebGpuExecutionProvider,CPUExecutionProvider"
# The same image with the wrapper's ROCM_PATH, HIP_PATH and PATH entry.
ROCM_FIXED="GPUR ENABLE false true false
GPUR ROCM_PATH /opt/rocm
GPUR HIP_PATH /opt/rocm
GPUR PATHROCM yes
GPUR ROCMDIR /opt/rocm
GPUR HIPVERSION 7.16.26385-0000000
GPUR HIPROCMPATH /opt/rocm
GPUR HIPCLANG /opt/rocm/core-10.1/lib/llvm/bin
GPUR HIPCC ok
GPUR MGXEP_ROOT /usr/local/lib/onnxruntime-ep-amdgpu
GPUR MGXEP_SO /usr/local/lib/onnxruntime-ep-amdgpu/lib/libmigraphx-ep.so
GPUR MGXEP_EXPORTS 2
GPUR MGXEP_UNRESOLVED
GPUR ORTEP MIGraphXExecutionProvider,WebGpuExecutionProvider,CPUExecutionProvider"
LIB=/usr/lib/x86_64-linux-gnu
DS=/opt/nvidia/deepstream/tensorrt-10.16.1.11/lib
CUDAEP=/usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_cuda.so
TRTEP=/usr/local/lib/onnxruntime-ep-tensorrt/lib/libonnxruntime_ep_tensorrt.so
TRT_GOOD="GPUR ENABLE true false true
GPUR ROCM_PATH
GPUR HIP_PATH
GPUR PATHROCM no
GPUR ROCMDIR <absent>
GPUR LDSO libnvinfer.so.10 ${DS}/libnvinfer.so.10
GPUR LDSO libnvinfer.so.11 ${LIB}/libnvinfer.so.11
GPUR LDSO libnvinfer_plugin.so.11 ${LIB}/libnvinfer_plugin.so.11
GPUR LDSO libnvonnxparser.so.11 ${LIB}/libnvonnxparser.so.11
GPUR TRTVER 10 101601
GPUR TRTVER 11 110400
GPUR TRTRES ${LIB}/libnvinfer_builder_resource_sm75.so.10.16.1
GPUR TRTRES ${LIB}/libnvinfer_builder_resource_sm75.so.11.4.0
GPUR TRTRES ${LIB}/libnvinfer_builder_resource_sm120.so.11.4.0
GPUR CUDAEP_SO ${CUDAEP}
GPUR CUDAEP_EXPORTS 2
GPUR CUDAEP_BRIDGE 0
GPUR ORTBUILD cuda-plugin-ep=1
GPUR TRTEP_ROOT /usr/local/lib/onnxruntime-ep-tensorrt
GPUR TRTEP_SO ${TRTEP}
GPUR TRTEP_EXPORTS 2
GPUR TRTEP_UNRESOLVED
GPUR TRTEP_DEP libnvinfer.so.11 ${LIB}/libnvinfer.so.11
GPUR TRTEP_DEP libnvinfer_plugin.so.11 ${LIB}/libnvinfer_plugin.so.11
GPUR TRTEP_DEP libnvonnxparser.so.11 ${LIB}/libnvonnxparser.so.11
GPUR ORTEP TensorrtExecutionProvider,CUDAExecutionProvider,CPUExecutionProvider"
# The published :latest-nvidia (2026-10-19): DeepStream's TensorRT 10 only, the legacy in-tree CUDA EP in a wheel without the plugin.
TRT_NONE="GPUR ENABLE true false false
GPUR ROCM_PATH
GPUR HIP_PATH
GPUR PATHROCM no
GPUR ROCMDIR <absent>
GPUR LDSO libnvinfer.so.10 ${DS}/libnvinfer.so.10
GPUR TRTVER 10 101601
GPUR CUDAEP_SO ${CUDAEP}
GPUR CUDAEP_EXPORTS 2
GPUR CUDAEP_BRIDGE 1
GPUR ORTBUILD -
GPUR TRTEP_ROOT <unset>
GPUR TRTEP_SO <absent>
GPUR ORTEP CUDAExecutionProvider,CPUExecutionProvider"

# An arm64 CPU image with the plugin QNN EP as the wrapper ships it.
QNN_ARM64="GPUR ENABLE false false false
GPUR ROCM_PATH
GPUR HIP_PATH
GPUR PATHROCM no
GPUR ROCMDIR <absent>
GPUR ARCH aarch64
GPUR QNNEP_ROOT /usr/local/lib/onnxruntime-ep-qnn
GPUR QNNEP_SO /usr/local/lib/onnxruntime-ep-qnn/lib/libonnxruntime_providers_qnn.so
GPUR QNNEP_EXPORTS 2
GPUR QNNEP_BACKENDS 21
GPUR ORTEP CPUExecutionProvider"

_bad() { printf '%s\n' "$1" | grep -c '^BAD' || true; }
_qnn() { accel_qnn_plugin_verdict "$1"; }
_rocm() { gpu_rocm_verdict "$1"; }
_trt() { gpu_tensorrt_verdict "$1" "${2:-11.4.0.106}"; }
_sdk() { gpu_tensorrt_sdk_verdict "$1"; }
_cuda() { gpu_cuda_plugin_verdict "$1"; }
# <probe> <line to drop or rewrite as sed expression>
_edit() { printf '%s\n' "$1" | sed "$2"; }
# <rocm|trt> <probe> <sed expression> <expected> [message]: the edited probe's verdict holds the expected line.
_finds() { t_assert_contains "$("_$1" "$(_edit "$2" "$3")")" "$4" "${5:-}"; }

t_case "the published :latest-rocm fails on every root it lacks, and its hipcc cannot link"
v="$(_rocm "${ROCM_SHIPPED}")"
t_assert_contains "${v}" "BAD ROCM_PATH is '<unset>', not /opt/rocm"
t_assert_contains "${v}" "BAD HIP_PATH is '<unset>', not /opt/rocm"
t_assert_contains "${v}" "BAD /opt/rocm/bin is not on PATH"
t_assert_contains "${v}" "BAD the hipconfig on PATH names '${SDK}', not /opt/rocm"
t_assert_contains "${v}" "BAD hipcc's clang is '${SDK}/lib/llvm/bin'"
t_assert_contains "${v}" "BAD hipcc cannot build a HIP program: fail ld.lld"
t_assert_contains "${v}" "BAD ORT_AMDGPU_EP_ROOT is '<unset>', not /usr/local/lib/onnxruntime-ep-amdgpu"
t_assert_contains "${v}" "BAD the plugin MIGraphX EP libmigraphx-ep.so is missing"
t_assert_eq 8 "$(_bad "${v}")" "eight findings"

t_case "the fixed wrapper passes"
v="$(_rocm "${ROCM_FIXED}")"
t_assert_eq 0 "$(_bad "${v}")" "no BAD line: ${v}"
t_assert_contains "${v}" "OK hipcc builds a HIP program for gfx1201"
t_assert_contains "${v}" "OK libmigraphx-ep.so exports CreateEpFactories and ReleaseEpFactory"
t_assert_contains "${v}" "OK libmigraphx-ep.so resolves every library it needs"

t_case "the plugin EP is judged on its own: exports, closure, and a non-rocm image must not advertise it"
_finds rocm "${ROCM_FIXED}" 's/^GPUR MGXEP_EXPORTS 2$/GPUR MGXEP_EXPORTS 1/' "BAD libmigraphx-ep.so exports 1 of the 2 plugin entry points"
_finds rocm "${ROCM_FIXED}" 's/^GPUR MGXEP_UNRESOLVED.*$/GPUR MGXEP_UNRESOLVED libonnxruntime.so.1/' "BAD libmigraphx-ep.so cannot resolve: libonnxruntime.so.1"
_finds rocm "${ROCM_FIXED}" 's#^GPUR MGXEP_ROOT .*#GPUR MGXEP_ROOT /opt/ep#' "BAD ORT_AMDGPU_EP_ROOT is '/opt/ep', not /usr/local/lib/onnxruntime-ep-amdgpu"
_finds rocm "${ROCM_FIXED}" 's/^GPUR ENABLE false true false$/GPUR ENABLE false false false/; s#^GPUR ROCM_PATH .*#GPUR ROCM_PATH <unset>#; s#^GPUR HIP_PATH .*#GPUR HIP_PATH <unset>#; s/^GPUR PATHROCM yes$/GPUR PATHROCM no/' \
  "BAD a non-rocm image advertises ORT_AMDGPU_EP_ROOT='/usr/local/lib/onnxruntime-ep-amdgpu'"

t_case "each rocm root and tool is judged on its own"
_finds rocm "${ROCM_FIXED}" 's|^GPUR HIP_PATH .*|GPUR HIP_PATH /opt/rocm-10.1|' "BAD HIP_PATH is '/opt/rocm-10.1'"
_finds rocm "${ROCM_FIXED}" 's|^GPUR ROCMDIR .*|GPUR ROCMDIR <absent>|' "BAD ENABLE_AMD=true but the image has no /opt/rocm"
_finds rocm "${ROCM_FIXED}" '/^GPUR HIPVERSION/d' "BAD /opt/rocm/bin/hipconfig --version printed nothing"
t_assert_eq "" "$(declare -F _gpur_ep)" "no verdict reads onnxruntime's compile-time provider list: the plugin EPs are not in it"
_finds rocm "${ROCM_FIXED}" '/^GPUR HIPCC/d' "BAD hipcc cannot build a HIP program"

t_case "a non-rocm image advertises no ROCm root"
t_assert_eq 0 "$(_bad "$(_rocm "${TRT_GOOD}")")" "empty ROCM_PATH/HIP_PATH, no /opt/rocm/bin"
_finds rocm "${TRT_GOOD}" 's|^GPUR ROCM_PATH.*|GPUR ROCM_PATH /opt/rocm|' "BAD a non-rocm image advertises ROCM_PATH='/opt/rocm'"
_finds rocm "${TRT_GOOD}" 's|^GPUR PATHROCM no|GPUR PATHROCM yes|' "BAD a non-rocm image puts /opt/rocm/bin on PATH"
t_assert_eq 0 "$(_bad "$(_rocm "$(_edit "${TRT_GOOD}" 's|^GPUR ROCM_PATH.*|GPUR ROCM_PATH <unset>|; s|^GPUR HIP_PATH.*|GPUR HIP_PATH <unset>|')")")" \
  "an image built before the ENV existed has them unset"

t_case "TensorRT 11 beside DeepStream's 10 passes"
v="$(_trt "${TRT_GOOD}")"
t_assert_eq 0 "$(_bad "${v}")" "no BAD line: ${v}"
t_assert_contains "${v}" "OK getInferLibVersion() is 110400 (TensorRT 11.4.0.106)"
t_assert_contains "${v}" "OK 2 builder resources in the default lib dir" "only the .so.11.* ones count"

t_case "the published :latest-nvidia has no TensorRT 11, which is right only without ENABLE_TENSORRT"
t_assert_eq 0 "$(_bad "$(_trt "${TRT_NONE}")")"
v="$(_trt "$(_edit "${TRT_NONE}" 's|^GPUR ENABLE .*|GPUR ENABLE true false true|')")"
t_assert_contains "${v}" "BAD libnvinfer.so.11 resolves to '', not the default lib dir"
t_assert_contains "${v}" "BAD ORT_TENSORRT_EP_ROOT is '<unset>', not /usr/local/lib/onnxruntime-ep-tensorrt"
t_assert_contains "${v}" "BAD the plugin TensorRT EP libonnxruntime_ep_tensorrt.so is missing"
_finds trt "${TRT_GOOD}" 's|^GPUR ENABLE .*|GPUR ENABLE true false false|' \
  "BAD ENABLE_TENSORRT is not true, but the loader resolves TensorRT 11"
_finds trt "${TRT_NONE}" "s|^GPUR TRTEP_SO <absent>|GPUR TRTEP_SO ${TRTEP}|" "BAD a plugin TensorRT EP ships without TensorRT: ${TRTEP}"
_finds trt "${TRT_NONE}" 's|^GPUR TRTEP_ROOT .*|GPUR TRTEP_ROOT /usr/local/lib/onnxruntime-ep-tensorrt|' \
  "BAD an image without ENABLE_TENSORRT advertises ORT_TENSORRT_EP_ROOT='/usr/local/lib/onnxruntime-ep-tensorrt'"

t_case "every TensorRT runtime fault is its own finding"
_finds trt "${TRT_GOOD}" 's|^GPUR TRTVER 11 .*|GPUR TRTVER 11 110300|' \
  "BAD getInferLibVersion() of libnvinfer.so.11 is '110300', TENSORRT_VERSION is 11.4.0.106"
_finds trt "${TRT_GOOD}" '/\.so\.11\.4\.0$/d' "BAD no TensorRT 11 builder resource"
_finds trt "${TRT_GOOD}" "s|^GPUR LDSO libnvonnxparser.so.11 .*|GPUR LDSO libnvonnxparser.so.11 /usr/local/tensorrt/lib/libnvonnxparser.so.11|" \
  "BAD libnvonnxparser.so.11 resolves to '/usr/local/tensorrt/lib/libnvonnxparser.so.11'"
t_assert_contains "$(gpu_tensorrt_verdict "${TRT_GOOD}" "")" "BAD no TENSORRT_VERSION to check the image against"

t_case "the plugin TensorRT EP is judged on its own: root, exports, closure, and TensorRT 11 from the default lib dir"
for _ok in "ORT_TENSORRT_EP_ROOT=/usr/local/lib/onnxruntime-ep-tensorrt" "libonnxruntime_ep_tensorrt.so exports CreateEpFactories and ReleaseEpFactory" \
           "libonnxruntime_ep_tensorrt.so resolves every library it needs" "the plugin TensorRT EP loads TensorRT 11 from the default lib dir"; do
  t_assert_contains "$(_trt "${TRT_GOOD}")" "OK ${_ok}"
done
_finds trt "${TRT_GOOD}" '/^GPUR TRTEP_SO /d' "BAD the plugin TensorRT EP libonnxruntime_ep_tensorrt.so is missing"
_finds trt "${TRT_GOOD}" 's#^GPUR TRTEP_ROOT .*#GPUR TRTEP_ROOT /opt/ep#' "BAD ORT_TENSORRT_EP_ROOT is '/opt/ep', not /usr/local/lib/onnxruntime-ep-tensorrt"
_finds trt "${TRT_GOOD}" 's/^GPUR TRTEP_EXPORTS 2$/GPUR TRTEP_EXPORTS 1/' "BAD libonnxruntime_ep_tensorrt.so exports 1 of the 2 plugin entry points"
_finds trt "${TRT_GOOD}" 's/^GPUR TRTEP_UNRESOLVED.*$/GPUR TRTEP_UNRESOLVED libnvinfer_plugin.so.11/' \
  "BAD libonnxruntime_ep_tensorrt.so cannot resolve: libnvinfer_plugin.so.11"
_finds trt "${TRT_GOOD}" "s|^GPUR TRTEP_DEP libnvinfer.so.11 .*|GPUR TRTEP_DEP libnvinfer.so.11 NOTFOUND|" "libnvinfer.so.11 NOTFOUND"
_finds trt "${TRT_GOOD}" "s|^GPUR TRTEP_DEP libnvinfer.so.11 .*|GPUR TRTEP_DEP libnvinfer.so.10 ${DS}/libnvinfer.so.10|" \
  "libnvinfer.so.10" "an EP linked against DeepStream's TensorRT 10 is caught"
_finds trt "${TRT_GOOD}" "\$a GPUR TRTEP_DEP libtensorrt_shim.so NOTFOUND" "libtensorrt_shim.so" \
  "the dev package's shim must not be a runtime dependency"

t_case "the CUDA EP is the plugin EP: both entry points, no GetProvider bridge, a wheel that registers it; no in-tree provider anywhere"
t_assert_eq 0 "$(_bad "$(_cuda "${TRT_GOOD}")")" "no BAD line: $(_cuda "${TRT_GOOD}")"
t_assert_contains "$(_cuda "${TRT_GOOD}")" "OK ${CUDAEP} is the plugin CUDA EP (CreateEpFactories and ReleaseEpFactory, no GetProvider)"
t_assert_contains "$(_cuda "${TRT_GOOD}")" "OK the venv's onnxruntime was built with the CUDA plugin EP and registers it on import"
v="$(_cuda "${TRT_NONE}")"
t_assert_eq 2 "$(_bad "${v}")" "the published :latest-nvidia carries the legacy CUDA EP in a wheel without the plugin"
t_assert_contains "${v}" "BAD ${CUDAEP} exports 2 plugin entry points and 1 GetProvider: the legacy CUDA EP, not the plugin" "the in-tree module carries both plugin entry points too; only the bridge tells"
t_assert_contains "${v}" "BAD the venv's onnxruntime build info lacks cuda-plugin-ep=1; nothing registers the CUDA EP"
_finds cuda "${TRT_GOOD}" 's/^GPUR CUDAEP_BRIDGE 0$/GPUR CUDAEP_BRIDGE 1/' "BAD ${CUDAEP} exports 2 plugin entry points and 1 GetProvider"
_finds cuda "${TRT_GOOD}" '/^GPUR CUDAEP_SO /d' "BAD ENABLE_NVIDIA=true but the GPU prefix has no libonnxruntime_providers_cuda.so"
_finds cuda "${TRT_GOOD}" "\$a GPUR ORTINTREE /usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_tensorrt.so" \
  "BAD an in-tree ORT provider ships: /usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_tensorrt.so (the TensorRT and MIGraphX EPs are plugins)"
_finds cuda "${ROCM_FIXED}" "\$a GPUR ORTINTREE /opt/venv/lib/python3.15/site-packages/onnxruntime/capi/libonnxruntime_providers_migraphx.so" \
  "BAD an in-tree ORT provider ships: /opt/venv/lib/python3.15/site-packages/onnxruntime/capi/libonnxruntime_providers_migraphx.so"
t_assert_eq 0 "$(_bad "$(_cuda "${ROCM_FIXED}")")" "a rocm image has no CUDA EP and no in-tree provider"
_finds cuda "${ROCM_FIXED}" "\$a GPUR CUDAEP_SO ${CUDAEP}" "BAD a non-nvidia image ships ${CUDAEP}"
t_assert_eq 0 "$(_bad "$(_cuda "${QNN_ARM64}")")" "an arm64 CPU image neither"

t_case "no image ships TensorRT's SDK, whatever ENABLE_TENSORRT says (owner 2026-10-21)"
t_assert_contains "$(_sdk "${TRT_GOOD}")" "OK only TensorRT's runtime .so files ship"
t_assert_contains "$(_sdk "${TRT_NONE}")" "OK only TensorRT's runtime .so files ship" "DeepStream's prefix without headers or dev links"
_finds sdk "${TRT_GOOD}" "\$a GPUR TRTHDR ${LIB%/lib/*}/include/x86_64-linux-gnu/NvInfer.h" \
  "BAD the SLA lets only the runtime .so files ship"
_finds sdk "${TRT_GOOD}" "\$a GPUR TRTDEV ${LIB}/libnvinfer.so" "${LIB}/libnvinfer.so"
_finds sdk "${TRT_GOOD}" "\$a GPUR TRTBIN /usr/src/tensorrt/bin/trtexec" "BAD the SLA lets only the runtime .so files ship" "trtexec"
_finds sdk "${TRT_GOOD}" "\$a GPUR TRTPY /opt/venv/lib/python3.15/site-packages/tensorrt/__init__.py" "tensorrt/__init__.py" "the Python binding"
# The published :latest-nvidia (2026-10-19), probed on 2026-10-21: DeepStream's TensorRT 10 headers and dev links.
TRT_DS_SHIPPED="${TRT_NONE}
GPUR TRTHDR /opt/nvidia/deepstream/tensorrt-10.16.1.11/include/NvInferRuntimePlugin.h
GPUR TRTDEV ${DS}/libnvinfer.so
GPUR TRTDEV ${DS}/libnvinfer_plugin.so
GPUR TRTDEV ${DS}/libnvonnxparser.so"
t_assert_contains "$(_sdk "${TRT_DS_SHIPPED}")" "BAD the SLA lets only the runtime .so files ship, but the image has: /opt/nvidia/deepstream/tensorrt-10.16.1.11/include/NvInferRuntimePlugin.h"
t_assert_eq 3 "$(_bad "$(gpu_runtime_verdict "${TRT_DS_SHIPPED}" 11.4.0.106)")" "an image without ENABLE_TENSORRT is judged too: the SDK finding plus the legacy CUDA EP's two"
_PROBE="$(gpu_runtime_probe_script)"
t_assert_contains "${_PROBE}" "/opt/nvidia/deepstream/tensorrt-*/lib/*.so; do" "the probe lists DeepStream's dev links"
t_assert_contains "${_PROBE}" "/usr/local/tensorrt /opt/nvidia \\( -name 'NvInfer*.h'" "and its headers"
t_assert_contains "${_PROBE}" 'cudaep=/usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_cuda.so' "the probe reads the CUDA EP's exports"
t_assert_contains "${_PROBE}" "GPUR CUDAEP_BRIDGE" "and counts the legacy GetProvider bridge"
t_assert_contains "${_PROBE}" "-name 'libonnxruntime_providers_tensorrt.so' -o -name 'libonnxruntime_providers_migraphx.so'" "and lists every in-tree provider file"
t_assert_contains "${_PROBE}" "grep -oE 'cuda-plugin-ep=1'" "and the wheel's build info flag"
t_assert_contains "${_PROBE}" 'trtep="${ORT_TENSORRT_EP_ROOT:-/usr/local/lib/onnxruntime-ep-tensorrt}/lib/libonnxruntime_ep_tensorrt.so"' "and the plugin TensorRT EP where the root says"

t_case "a probe that never ran fails once, never reads as an image without a GPU stack"
t_assert_eq "BAD the GPU probe printed nothing; the container did not run it" "$(gpu_runtime_verdict "" 11.4.0.106)"
t_assert_eq 0 "$(_bad "$(gpu_runtime_verdict "${TRT_GOOD}" 11.4.0.106)")" "a real probe goes through every verdict"
t_assert_eq 8 "$(_bad "$(gpu_runtime_verdict "${ROCM_SHIPPED}" 11.4.0.106)")" "six roots and tools plus the two plugin EP findings"
t_assert_contains "$(declare -f check_gpu_runtime)" "gpu_runtime_verdict" "the smoke check uses it"

t_case "the wrapper's ROCm environment exists only in a rocm image"
PKG="${TESTS_DIR}/../../Dockerfile.package"
t_assert_contains "$(cat "${PKG}")" 'ARG ROCM_ON=${ENABLE_AMD/false/}'
t_assert_contains "$(cat "${PKG}")" $'ENV ROCM_PATH=${ROCM_ON:+/opt/rocm} \\\n    HIP_PATH=${ROCM_ON:+/opt/rocm}'
t_assert_contains "$(cat "${PKG}")" 'ENV PATH="${PATH}${ROCM_ON:+:/opt/rocm/bin}"' "appended, so ROCm shadows no image tool"

t_case "the entrypoint names the flag that opens a GPU node closed to uid 1001"
ENTRY="${TESTS_DIR}/../04-runtime/entrypoint.sh"
_hint() { bash -c "$(t_fn_src "${ENTRY}" _gpu_node_hint)"$'\n_gpu_node_hint "$@"' _ "$@"; }
t_assert_contains "$(_hint /dev/kfd 109)" "/dev/kfd is closed to uid $(id -u): add --group-add 109 to the run"
t_assert_contains "$(_hint /dev/dri/renderD128 65534)" "unmapped (rootless engine): make the node mode 0666 on the host" \
  "a rootless engine maps no host group, so --group-add cannot help"
t_assert_contains "$(cat "${ENTRY}")" 'for _gpu_node in /dev/kfd /dev/dri/renderD*; do' "kfd and every render node"

t_case "the plugin QNN EP: arm64 must ship it where ORT_QNN_EP_ROOT says, every other arch must not even advertise it"
t_assert_eq 0 "$(_bad "$(_qnn "${QNN_ARM64}")")" "$(_qnn "${QNN_ARM64}")"
t_assert_contains "$(_qnn "${QNN_ARM64}")" "OK 21 QAIRT backend libraries sit beside the plugin"
_finds qnn "${QNN_ARM64}" 's|^GPUR QNNEP_SO .*|GPUR QNNEP_SO <absent>|' "BAD the plugin QNN EP libonnxruntime_providers_qnn.so is missing"
_finds qnn "${QNN_ARM64}" 's|^GPUR QNNEP_EXPORTS 2$|GPUR QNNEP_EXPORTS 1|' "BAD libonnxruntime_providers_qnn.so exports 1 of the 2 plugin entry points"
_finds qnn "${QNN_ARM64}" 's|^GPUR QNNEP_BACKENDS 21$|GPUR QNNEP_BACKENDS 0|' "BAD no libQnn*.so beside the plugin QNN EP"
_finds qnn "${QNN_ARM64}" 's|^GPUR QNNEP_ROOT .*|GPUR QNNEP_ROOT <unset>|' "BAD ORT_QNN_EP_ROOT is '<unset>', not /usr/local/lib/onnxruntime-ep-qnn"
t_assert_eq 0 "$(_bad "$(_qnn "${TRT_GOOD}")")" "an amd64 probe without the QNN facts is clean"
_finds qnn "${TRT_GOOD}" 's|^GPUR ROCMDIR <absent>|GPUR ROCMDIR <absent>\nGPUR ARCH x86_64\nGPUR QNNEP_ROOT /usr/local/lib/onnxruntime-ep-qnn|' "BAD a non-arm64 image advertises ORT_QNN_EP_ROOT='/usr/local/lib/onnxruntime-ep-qnn'"
_finds qnn "${TRT_GOOD}" 's|^GPUR ROCMDIR <absent>|GPUR ROCMDIR <absent>\nGPUR ARCH x86_64\nGPUR QNNEP_SO /x/libonnxruntime_providers_qnn.so|' "BAD a non-arm64 image ships the plugin QNN EP /x/libonnxruntime_providers_qnn.so"
t_assert_contains "$(t_fn_src "${TESTS_DIR}/../06-packaging/check-gpu-runtime.sh" gpu_runtime_verdict)" 'accel_qnn_plugin_verdict "$1"' "the runner judges the plugin on every image"

t_case "the probe emits every fact the verdicts read"
p="$(gpu_runtime_probe_script)"
for k in ENABLE ROCM_PATH HIP_PATH PATHROCM ROCMDIR HIPVERSION HIPROCMPATH HIPCLANG HIPCC LDSO TRTVER TRTRES TRTHDR TRTDEV CUDAEP_SO CUDAEP_EXPORTS CUDAEP_BRIDGE ORTINTREE ORTBUILD TRTEP_ROOT TRTEP_SO TRTEP_EXPORTS TRTEP_UNRESOLVED TRTEP_DEP ARCH QNNEP_ROOT QNNEP_SO QNNEP_EXPORTS QNNEP_BACKENDS; do
  t_assert_contains "${p}" "GPUR ${k}" "the probe prints GPUR ${k}"
done
t_assert_eq 0 "$(printf '%s\n' "${p}" | grep -c 'bash -l' || true)" "no login shell resets PATH inside the probe"

t_summary
