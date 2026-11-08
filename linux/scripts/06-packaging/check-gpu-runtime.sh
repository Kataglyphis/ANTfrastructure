#!/usr/bin/env bash
# The GPU variants' runtime contract without a GPU: ROCm's roots and toolchain, TensorRT's runtime and the ORT EP that loads it. docs/linux-accelerator-images.md#the-gpu-runtime-gate

# Sourced by smoke-runtime-image.sh; sets no shell options.

# The in-image probe, run without a login shell: /etc/profile would reset the image's PATH. Its container is thrown away.
gpu_runtime_probe_script() {
  cat <<'PROBE'
set -uo pipefail
printf 'GPUR ENABLE %s %s %s\n' "${ENABLE_NVIDIA:-false}" "${ENABLE_AMD:-false}" "${ENABLE_TENSORRT:-false}"
printf 'GPUR ROCM_PATH %s\n' "${ROCM_PATH-<unset>}"
printf 'GPUR HIP_PATH %s\n' "${HIP_PATH-<unset>}"
printf 'GPUR MGXEP_ROOT %s\n' "${ORT_AMDGPU_EP_ROOT-<unset>}"
mgxep="${ORT_AMDGPU_EP_ROOT:-/usr/local/lib/onnxruntime-ep-amdgpu}/lib/libmigraphx-ep.so"
if [ -f "${mgxep}" ]; then
  echo "GPUR MGXEP_SO ${mgxep}"
  echo "GPUR MGXEP_EXPORTS $(readelf --dyn-syms -W "${mgxep}" 2>/dev/null | grep -cE ' (CreateEpFactories|ReleaseEpFactory)(@@[A-Za-z0-9_.]+)?$')"
  echo "GPUR MGXEP_UNRESOLVED $(ldd "${mgxep}" 2>/dev/null | awk '$2 == "=>" && $3 == "not" {print $1}' | tr '\n' ' ')"
else echo "GPUR MGXEP_SO <absent>"; fi
printf 'GPUR ARCH %s\n' "$(uname -m)"
printf 'GPUR QNNEP_ROOT %s\n' "${ORT_QNN_EP_ROOT-<unset>}"
qnnep="${ORT_QNN_EP_ROOT:-/usr/local/lib/onnxruntime-ep-qnn}/lib/libonnxruntime_providers_qnn.so"
if [ -f "${qnnep}" ]; then
  echo "GPUR QNNEP_SO ${qnnep}"
  echo "GPUR QNNEP_EXPORTS $(readelf --dyn-syms -W "${qnnep}" 2>/dev/null | grep -cE ' (CreateEpFactories|ReleaseEpFactory)(@@[A-Za-z0-9_.]+)?$')"
  echo "GPUR QNNEP_BACKENDS $(find "${qnnep%/*}" -maxdepth 1 -name 'libQnn*.so' -type f 2>/dev/null | wc -l)"
else echo "GPUR QNNEP_SO <absent>"; fi
case ":${PATH}:" in *:/opt/rocm/bin:*) echo "GPUR PATHROCM yes" ;; *) echo "GPUR PATHROCM no" ;; esac
if [ -d /opt/rocm ]; then echo "GPUR ROCMDIR $(readlink -f /opt/rocm)"; else echo "GPUR ROCMDIR <absent>"; fi
# The venv's rocm-sdk shims come first on PATH; with ROCM_PATH they hand over to /opt/rocm.
if [ -x /opt/rocm/bin/hipconfig ]; then echo "GPUR HIPVERSION $(/opt/rocm/bin/hipconfig --version 2>/dev/null | head -1)"; fi
if command -v hipconfig >/dev/null 2>&1; then
  echo "GPUR HIPROCMPATH $(readlink -f "$(hipconfig --rocmpath 2>/dev/null)" 2>/dev/null)"
  echo "GPUR HIPCLANG $(readlink -f "$(hipconfig --hipclangpath 2>/dev/null)" 2>/dev/null)"
fi
if [ -d /opt/rocm ] && command -v hipcc >/dev/null 2>&1; then
  w="$(mktemp -d)"
  printf '#include <hip/hip_runtime.h>\n__global__ void k(float *x) { x[threadIdx.x] *= 2.f; }\nint main() { return 0; }\n' > "${w}/k.hip"
  if out="$(hipcc --offload-arch=gfx1201 "${w}/k.hip" -o "${w}/k" 2>&1)"; then echo "GPUR HIPCC ok"
  else echo "GPUR HIPCC fail $(printf '%s' "${out}" | grep -m1 -E 'error' || printf '%s' "${out}" | tail -1)"; fi
fi
ldconfig -p 2>/dev/null | awk '$1 ~ /^lib(nvinfer|nvinfer_plugin|nvonnxparser)\.so\.[0-9]+$/ {print "GPUR LDSO", $1, $NF}'
for so in $(ldconfig -p 2>/dev/null | awk '$1 ~ /^libnvinfer\.so\.[0-9]+$/ {print $1}' | sort -u); do
  v="$(python3 -I -c 'import ctypes, sys; print(ctypes.CDLL(sys.argv[1]).getInferLibVersion())' "${so}" 2>&1 | tail -1)"
  echo "GPUR TRTVER ${so##*.so.} ${v}"
done
lib="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null)"
for f in "${lib}"/libnvinfer_builder_resource*.so.*; do [ -f "${f}" ] && echo "GPUR TRTRES ${f}"; done
find /usr/include /usr/local/include /usr/local/tensorrt /opt/nvidia \( -name 'NvInfer*.h' -o -name 'NvOnnxParser*.h' \) 2>/dev/null | head -3 | sed 's/^/GPUR TRTHDR /'
# DeepStream's TensorRT 10 prefix too: its loader path keys it by soname, so an unversioned .so there is a dev link.
for f in "${lib}"/libnvinfer.so "${lib}"/libnvinfer_plugin.so "${lib}"/libnvonnxparser.so "${lib}"/libtensorrt_shim.so /opt/nvidia/deepstream/tensorrt-*/lib/*.so; do
  [ -e "${f}" ] && echo "GPUR TRTDEV ${f}"
done
for f in $(command -v trtexec 2>/dev/null) /usr/src/tensorrt/bin/trtexec; do [ -e "${f}" ] && echo "GPUR TRTBIN ${f}"; done
py="$(/opt/venv/bin/python -I -c 'import importlib.util as u; s = u.find_spec("tensorrt"); print(s.origin if s else "")' 2>/dev/null)"
[ -z "${py}" ] || echo "GPUR TRTPY ${py}"
for f in $(find /usr/local/lib/onnxruntime-gpu /opt/venv/lib/python3*/site-packages/onnxruntime -name 'libonnxruntime_providers_tensorrt.so' 2>/dev/null); do
  echo "GPUR ORTTRT ${f}"
  ldd "${f}" 2>/dev/null | awk -v f="${f}" '$1 ~ /^lib(nvinfer|nvonnxparser|tensorrt)/ {print "GPUR ORTDEP", f, $1, ($3 == "not" ? "NOTFOUND" : $3)}'
done
echo "GPUR ORTEP $(/opt/venv/bin/python -I -c 'import onnxruntime as o; print(",".join(o.get_available_providers()))' 2>/dev/null || echo '<none>')"
PROBE
}

# <probe> <key>: the values after "GPUR <key> ", one per line.
_gpur() { printf '%s\n' "$1" | sed -n "s/^GPUR $2 //p"; }

# <probe> <1|2|3>: ENABLE_NVIDIA, ENABLE_AMD or ENABLE_TENSORRT as the image saw it.
_gpur_on() { _gpur "$1" ENABLE | awk -v i="$2" '{print $i}'; }

# <probe> <provider>: OK or BAD, by onnxruntime's own provider list.
_gpur_ep() {
  case ",$(_gpur "$1" ORTEP)," in
    *,"$2",*) echo "OK onnxruntime lists $2" ;;
    *) echo "BAD onnxruntime lacks $2: $(_gpur "$1" ORTEP)" ;;
  esac
}

# <probe>: a non-rocm image must advertise no ROCm root, PATH entry or plugin EP root.
_gpu_rocm_absent_verdict() {
  local probe="$1"
  case "$(_gpur "${probe}" ROCM_PATH)$(_gpur "${probe}" HIP_PATH)" in
    ""|"<unset><unset>") echo "OK no ROCm root is advertised" ;;
    *) echo "BAD a non-rocm image advertises ROCM_PATH='$(_gpur "${probe}" ROCM_PATH)' HIP_PATH='$(_gpur "${probe}" HIP_PATH)'" ;;
  esac
  [ "$(_gpur "${probe}" PATHROCM)" = no ] || echo "BAD a non-rocm image puts /opt/rocm/bin on PATH"
  case "$(_gpur "${probe}" MGXEP_ROOT)" in ""|"<unset>") ;; *) echo "BAD a non-rocm image advertises ORT_AMDGPU_EP_ROOT='$(_gpur "${probe}" MGXEP_ROOT)'" ;; esac
}

# <probe>: the two roots, the PATH entry and the HIP version the wrapper must set.
_gpu_rocm_roots_verdict() {
  local probe="$1" k
  for k in ROCM_PATH HIP_PATH; do
    if [ "$(_gpur "${probe}" "${k}")" = /opt/rocm ]; then echo "OK ${k}=/opt/rocm"; else echo "BAD ${k} is '$(_gpur "${probe}" "${k}")', not /opt/rocm"; fi
  done
  if [ "$(_gpur "${probe}" PATHROCM)" = yes ]; then echo "OK /opt/rocm/bin is on PATH"; else echo "BAD /opt/rocm/bin is not on PATH"; fi
  if [ -n "$(_gpur "${probe}" HIPVERSION)" ]; then echo "OK /opt/rocm carries HIP $(_gpur "${probe}" HIPVERSION)"; else echo "BAD /opt/rocm/bin/hipconfig --version printed nothing"; fi
}

# <probe>: an AMD image needs its roots and a working hipcc, any other image none of them.
gpu_rocm_verdict() {
  local probe="$1" root
  if [ "$(_gpur_on "${probe}" 2)" != true ]; then _gpu_rocm_absent_verdict "${probe}"; return 0; fi
  root="$(_gpur "${probe}" ROCMDIR)"
  [ "${root}" != "<absent>" ] || { echo "BAD ENABLE_AMD=true but the image has no /opt/rocm"; return 0; }
  _gpu_rocm_roots_verdict "${probe}"
  if [ "$(_gpur "${probe}" HIPROCMPATH)" = "${root}" ]; then echo "OK the hipconfig on PATH names ${root}"
  else echo "BAD the hipconfig on PATH names '$(_gpur "${probe}" HIPROCMPATH)', not ${root}"; fi
  case "$(_gpur "${probe}" HIPCLANG)" in
    "${root}"/*) echo "OK hipcc's clang is ${root}'s" ;;
    *) echo "BAD hipcc's clang is '$(_gpur "${probe}" HIPCLANG)', not ${root}'s" ;;
  esac
  case "$(_gpur "${probe}" HIPCC)" in
    ok) echo "OK hipcc builds a HIP program for gfx1201" ;;
    *) echo "BAD hipcc cannot build a HIP program: $(_gpur "${probe}" HIPCC)" ;;
  esac
  _gpur_ep "${probe}" MIGraphXExecutionProvider
  gpu_plugin_ep_verdict "${probe}"
}

# <probe> <key> <expected root> <module> <root variable> <label>: the root, the module and its two exports, as every plugin EP verdict reads them; 1 when the module is missing.
_plugin_ep_verdict() {
  local probe="$1" k="$2" want="$3" so="$4" var="$5" label="$6" root
  root="$(_gpur "${probe}" "${k}_ROOT")"
  if [ "${root}" = "${want}" ]; then echo "OK ${var}=${root}"; else echo "BAD ${var} is '${root}', not ${want}"; fi
  case "$(_gpur "${probe}" "${k}_SO")" in
    ""|"<absent>") echo "BAD the plugin ${label} ${so} is missing"; return 1 ;;
    *) echo "OK ${so} is shipped" ;;
  esac
  if [ "$(_gpur "${probe}" "${k}_EXPORTS")" = 2 ]; then echo "OK ${so} exports CreateEpFactories and ReleaseEpFactory"
  else echo "BAD ${so} exports $(_gpur "${probe}" "${k}_EXPORTS") of the 2 plugin entry points"; fi
}

# <probe>: the rocm image ships AMD's plugin MIGraphX EP where ORT_AMDGPU_EP_ROOT says, with its two exports and a resolvable closure.
gpu_plugin_ep_verdict() {
  local probe="$1"
  _plugin_ep_verdict "${probe}" MGXEP /usr/local/lib/onnxruntime-ep-amdgpu libmigraphx-ep.so ORT_AMDGPU_EP_ROOT "MIGraphX EP" || return 0
  if [ -z "$(_gpur "${probe}" MGXEP_UNRESOLVED | tr -d ' ')" ]; then echo "OK libmigraphx-ep.so resolves every library it needs"
  else echo "BAD libmigraphx-ep.so cannot resolve: $(_gpur "${probe}" MGXEP_UNRESOLVED)"; fi
}

# <probe>: arm64 ships Qualcomm's plugin QNN EP where ORT_QNN_EP_ROOT says, with its exports and QAIRT backends; every other arch neither advertises nor ships it.
accel_qnn_plugin_verdict() {
  local probe="$1" root so
  root="$(_gpur "${probe}" QNNEP_ROOT)"; so="$(_gpur "${probe}" QNNEP_SO)"
  if [ "$(_gpur "${probe}" ARCH)" != aarch64 ]; then
    case "${root}" in ""|"<unset>") ;; *) echo "BAD a non-arm64 image advertises ORT_QNN_EP_ROOT='${root}'" ;; esac
    case "${so}" in ""|"<absent>") ;; *) echo "BAD a non-arm64 image ships the plugin QNN EP ${so}" ;; esac
    return 0
  fi
  _plugin_ep_verdict "${probe}" QNNEP /usr/local/lib/onnxruntime-ep-qnn libonnxruntime_providers_qnn.so ORT_QNN_EP_ROOT "QNN EP" || return 0
  case "$(_gpur "${probe}" QNNEP_BACKENDS)" in
    ""|0) echo "BAD no libQnn*.so beside the plugin QNN EP" ;;
    *) echo "OK $(_gpur "${probe}" QNNEP_BACKENDS) QAIRT backend libraries sit beside the plugin" ;;
  esac
}

# <probe> <TENSORRT_VERSION>: TensorRT's runtime in the default lib dir, nothing else of its SDK, and the EP that loads it.
gpu_tensorrt_verdict() {
  local probe="$1" want="$2" m="${2%%.*}" mm pp got r f bad
  if [ "$(_gpur_on "${probe}" 3)" != true ]; then
    if _gpur "${probe}" LDSO | awk -v s=".so.${m}" 'substr($1, length($1) - length(s) + 1) == s' | grep -q .; then
      echo "BAD ENABLE_TENSORRT is not true, but the loader resolves TensorRT ${m}"
    else
      echo "OK no TensorRT ${m} in an image without ENABLE_TENSORRT"
    fi
    [ -z "$(_gpur "${probe}" ORTTRT)" ] || echo "BAD an ORT TensorRT EP ships without TensorRT: $(_gpur "${probe}" ORTTRT | tr '\n' ' ')"
    return 0
  fi
  [ -n "${m}" ] || { echo "BAD no TENSORRT_VERSION to check the image against"; return 0; }
  for f in libnvinfer libnvinfer_plugin libnvonnxparser; do
    r="$(_gpur "${probe}" LDSO | awk -v n="${f}.so.${m}" '$1 == n {print $2; exit}')"
    case "${r}" in
      /usr/lib/*-linux-gnu/*) echo "OK ${f}.so.${m} resolves to ${r}" ;;
      *) echo "BAD ${f}.so.${m} resolves to '${r}', not the default lib dir" ;;
    esac
  done
  IFS=. read -r _ mm pp _ <<< "${want}"
  got="$(_gpur "${probe}" TRTVER | awk -v m="${m}" '$1 == m {print $2}')"
  if [ "${got}" = "$(( m * 10000 + mm * 100 + pp ))" ]; then echo "OK getInferLibVersion() is ${got} (TensorRT ${want})"
  else echo "BAD getInferLibVersion() of libnvinfer.so.${m} is '${got}', TENSORRT_VERSION is ${want}"; fi
  if _gpur "${probe}" TRTRES | grep -qF ".so.${m}."; then echo "OK $(_gpur "${probe}" TRTRES | grep -cF ".so.${m}.") builder resources in the default lib dir"
  else echo "BAD no TensorRT ${m} builder resource in the default lib dir; no engine builds"; fi
  [ "$(_gpur "${probe}" ORTTRT | grep -c .)" -ge 2 ] \
    || echo "BAD the ORT TensorRT EP is not in both the native tree and the venv: $(_gpur "${probe}" ORTTRT | tr '\n' ' ')"
  bad="$(_gpur "${probe}" ORTDEP | awk -v s=".so.${m}" '
    $2 ~ /^libtensorrt/ {print; next}
    substr($2, length($2) - length(s) + 1) != s || $3 !~ /^\/usr\/lib\/[^\/]*-linux-gnu\// {print}')"
  if [ -z "${bad}" ] && [ -n "$(_gpur "${probe}" ORTDEP)" ]; then echo "OK the ORT TensorRT EP loads TensorRT ${m} from the default lib dir"
  else echo "BAD the ORT TensorRT EP resolves: $(printf '%s' "${bad:-nothing}" | tr '\n' ';')"; fi
  _gpur_ep "${probe}" TensorrtExecutionProvider
}

# <probe>: whatever ENABLE_TENSORRT says, no image ships a TensorRT header, dev link, trtexec or Python binding (owner 2026-10-21).
gpu_tensorrt_sdk_verdict() {
  local bad
  bad="$(_gpur "$1" TRTHDR; _gpur "$1" TRTDEV; _gpur "$1" TRTBIN; _gpur "$1" TRTPY)"
  if [ -z "${bad//[[:space:]]/}" ]; then echo "OK only TensorRT's runtime .so files ship (no headers, dev links, trtexec or Python binding)"
  else echo "BAD the SLA lets only the runtime .so files ship, but the image has: $(printf '%s' "${bad}" | tr '\n' ' ')"; fi
}

# <probe> <TENSORRT_VERSION>: every verdict, or one BAD when the probe never ran (an empty probe would read as "no GPU stack").
gpu_runtime_verdict() {
  _gpur "$1" ENABLE | grep -q . || { echo "BAD the GPU probe printed nothing; the container did not run it"; return 0; }
  gpu_rocm_verdict "$1"
  accel_qnn_plugin_verdict "$1"
  gpu_tensorrt_verdict "$1" "$2"
  gpu_tensorrt_sdk_verdict "$1"
}

# <image> <arch>: runs the probe in the shipped image and turns each verdict line into pass or fail.
check_gpu_runtime() {
  # shellcheck disable=SC2034  # _rt_run reads image_tag by dynamic scope
  local image_tag="$1" target_arch="$2" probe
  echo "--- GPU runtime: ROCm roots, TensorRT runtime and its EP (${target_arch}) ---"
  probe="$(_rt_run bash -c "$(gpu_runtime_probe_script)" 2>/dev/null)" || true
  smoke_verdict_lines GPU-RUNTIME "${target_arch}" < <(gpu_runtime_verdict "${probe}" "$(_rt_versions_env_pin TENSORRT_VERSION)")
  echo ""
}
