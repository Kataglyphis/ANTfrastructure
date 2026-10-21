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
GPUR ORTEP MIGraphXExecutionProvider,WebGpuExecutionProvider,CPUExecutionProvider"
LIB=/usr/lib/x86_64-linux-gnu
DS=/opt/nvidia/deepstream/tensorrt-10.16.1.11/lib
ORTN=/usr/local/lib/onnxruntime-gpu/lib/libonnxruntime_providers_tensorrt.so
ORTV=/opt/venv/lib/python3.15/site-packages/onnxruntime/capi/libonnxruntime_providers_tensorrt.so
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
GPUR ORTTRT ${ORTN}
GPUR ORTDEP ${ORTN} libnvinfer.so.11 ${LIB}/libnvinfer.so.11
GPUR ORTDEP ${ORTN} libnvonnxparser.so.11 ${LIB}/libnvonnxparser.so.11
GPUR ORTTRT ${ORTV}
GPUR ORTDEP ${ORTV} libnvinfer.so.11 ${LIB}/libnvinfer.so.11
GPUR ORTDEP ${ORTV} libnvonnxparser.so.11 ${LIB}/libnvonnxparser.so.11
GPUR ORTEP TensorrtExecutionProvider,CUDAExecutionProvider,CPUExecutionProvider"
# The published :latest-nvidia: DeepStream's TensorRT 10 only, the CUDA EP only.
TRT_NONE="GPUR ENABLE true false false
GPUR ROCM_PATH
GPUR HIP_PATH
GPUR PATHROCM no
GPUR ROCMDIR <absent>
GPUR LDSO libnvinfer.so.10 ${DS}/libnvinfer.so.10
GPUR TRTVER 10 101601
GPUR ORTEP CUDAExecutionProvider,CPUExecutionProvider"

_bad() { printf '%s\n' "$1" | grep -c '^BAD' || true; }
_rocm() { gpu_rocm_verdict "$1"; }
_trt() { gpu_tensorrt_verdict "$1" "${2:-11.4.0.106}"; }
_sdk() { gpu_tensorrt_sdk_verdict "$1"; }
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
t_assert_eq 6 "$(_bad "${v}")" "six findings, the EP listing still passes"

t_case "the fixed wrapper passes"
v="$(_rocm "${ROCM_FIXED}")"
t_assert_eq 0 "$(_bad "${v}")" "no BAD line: ${v}"
t_assert_contains "${v}" "OK hipcc builds a HIP program for gfx1201"
t_assert_contains "${v}" "OK onnxruntime lists MIGraphXExecutionProvider"

t_case "each rocm root and tool is judged on its own"
_finds rocm "${ROCM_FIXED}" 's|^GPUR HIP_PATH .*|GPUR HIP_PATH /opt/rocm-10.1|' "BAD HIP_PATH is '/opt/rocm-10.1'"
_finds rocm "${ROCM_FIXED}" 's|^GPUR ROCMDIR .*|GPUR ROCMDIR <absent>|' "BAD ENABLE_AMD=true but the image has no /opt/rocm"
_finds rocm "${ROCM_FIXED}" '/^GPUR HIPVERSION/d' "BAD /opt/rocm/bin/hipconfig --version printed nothing"
_finds rocm "${ROCM_FIXED}" 's|^GPUR ORTEP .*|GPUR ORTEP CPUExecutionProvider|' "BAD onnxruntime lacks MIGraphXExecutionProvider"
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
t_assert_contains "${v}" "BAD onnxruntime lacks TensorrtExecutionProvider"
_finds trt "${TRT_GOOD}" 's|^GPUR ENABLE .*|GPUR ENABLE true false false|' \
  "BAD ENABLE_TENSORRT is not true, but the loader resolves TensorRT 11"
_finds trt "${TRT_NONE}" "\$a GPUR ORTTRT ${ORTN}" "BAD an ORT TensorRT EP ships without TensorRT"

t_case "every TensorRT runtime fault is its own finding"
_finds trt "${TRT_GOOD}" 's|^GPUR TRTVER 11 .*|GPUR TRTVER 11 110300|' \
  "BAD getInferLibVersion() of libnvinfer.so.11 is '110300', TENSORRT_VERSION is 11.4.0.106"
_finds trt "${TRT_GOOD}" '/\.so\.11\.4\.0$/d' "BAD no TensorRT 11 builder resource"
_finds trt "${TRT_GOOD}" "s|^GPUR LDSO libnvonnxparser.so.11 .*|GPUR LDSO libnvonnxparser.so.11 /usr/local/tensorrt/lib/libnvonnxparser.so.11|" \
  "BAD libnvonnxparser.so.11 resolves to '/usr/local/tensorrt/lib/libnvonnxparser.so.11'"
_finds trt "${TRT_GOOD}" "\\|^GPUR ORTTRT ${ORTV}\$|d; \\|^GPUR ORTDEP ${ORTV} |d" \
  "BAD the ORT TensorRT EP is not in both the native tree and the venv"
_finds trt "${TRT_GOOD}" "s|^GPUR ORTDEP ${ORTV} libnvinfer.so.11 .*|GPUR ORTDEP ${ORTV} libnvinfer.so.11 NOTFOUND|" \
  "${ORTV} libnvinfer.so.11 NOTFOUND"
_finds trt "${TRT_GOOD}" "s|^GPUR ORTDEP ${ORTN} libnvinfer.so.11 .*|GPUR ORTDEP ${ORTN} libnvinfer.so.10 ${DS}/libnvinfer.so.10|" \
  "${ORTN} libnvinfer.so.10" "an EP linked against DeepStream's TensorRT 10 is caught"
_finds trt "${TRT_GOOD}" "\$a GPUR ORTDEP ${ORTN} libtensorrt_shim.so NOTFOUND" "libtensorrt_shim.so" \
  "the dev package's shim must not be a runtime dependency"
_finds trt "${TRT_GOOD}" 's|^GPUR ORTEP .*|GPUR ORTEP CUDAExecutionProvider,CPUExecutionProvider|' "BAD onnxruntime lacks TensorrtExecutionProvider"
t_assert_contains "$(gpu_tensorrt_verdict "${TRT_GOOD}" "")" "BAD no TENSORRT_VERSION to check the image against"

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
t_assert_eq 1 "$(_bad "$(gpu_runtime_verdict "${TRT_DS_SHIPPED}" 11.4.0.106)")" "an image without ENABLE_TENSORRT is judged too"
_PROBE="$(gpu_runtime_probe_script)"
t_assert_contains "${_PROBE}" "/opt/nvidia/deepstream/tensorrt-*/lib/*.so; do" "the probe lists DeepStream's dev links"
t_assert_contains "${_PROBE}" "/usr/local/tensorrt /opt/nvidia \\( -name 'NvInfer*.h'" "and its headers"

t_case "a probe that never ran fails once, never reads as an image without a GPU stack"
t_assert_eq "BAD the GPU probe printed nothing; the container did not run it" "$(gpu_runtime_verdict "" 11.4.0.106)"
t_assert_eq 0 "$(_bad "$(gpu_runtime_verdict "${TRT_GOOD}" 11.4.0.106)")" "a real probe goes through both verdicts"
t_assert_eq 6 "$(_bad "$(gpu_runtime_verdict "${ROCM_SHIPPED}" 11.4.0.106)")"
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

t_case "the probe emits every fact the verdicts read"
p="$(gpu_runtime_probe_script)"
for k in ENABLE ROCM_PATH HIP_PATH PATHROCM ROCMDIR HIPVERSION HIPROCMPATH HIPCLANG HIPCC LDSO TRTVER TRTRES TRTHDR TRTDEV ORTTRT ORTDEP ORTEP; do
  t_assert_contains "${p}" "GPUR ${k}" "the probe prints GPUR ${k}"
done
t_assert_eq 0 "$(printf '%s\n' "${p}" | grep -c 'bash -l' || true)" "no login shell resets PATH inside the probe"

t_summary
