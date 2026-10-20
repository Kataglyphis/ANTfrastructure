#!/usr/bin/env bash
# The GPU variant's CUDA/cuDNN/NCCL carry-over, without which CUDA-built libraries cannot load at runtime.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PAY="${TESTS_DIR}/../06-packaging/copy-media-payloads.sh"
PKG="${TESTS_DIR}/../../Dockerfile.package"

_FNS='warn() { printf "[WARN] %s\n" "$*" >&2; }'$'\n'
for _fn in _dest copy_path copy_glob copy_cuda_payload copy_tensorrt_payload; do
  _FNS+="$(t_fn_src "${PAY}" "${_fn}")"$'\n' || exit 1
done

# Shaped like the media image: cuda/cuda-13 are absolute alternatives links, which dangle through a bind mount.
_mk_artifact() {
  local a="$1"
  mkdir -p "${a}/usr/local/cuda-13.3/bin" "${a}/usr/local/cuda-13.3/targets/sbsa-linux/lib" \
    "${a}/usr/lib/aarch64-linux-gnu" "${a}/usr/include/aarch64-linux-gnu" "${a}/usr/include/nccl_device"
  echo nvcc > "${a}/usr/local/cuda-13.3/bin/nvcc"
  echo rt > "${a}/usr/local/cuda-13.3/targets/sbsa-linux/lib/libcudart.so.13"
  ln -s /etc/alternatives/cuda "${a}/usr/local/cuda"
  ln -s /etc/alternatives/cuda-13 "${a}/usr/local/cuda-13"
  echo dnn > "${a}/usr/lib/aarch64-linux-gnu/libcudnn.so.9.26.0"
  ln -s libcudnn.so.9.26.0 "${a}/usr/lib/aarch64-linux-gnu/libcudnn.so.9"
  echo nccl > "${a}/usr/lib/aarch64-linux-gnu/libnccl.so.2.31.2"
  echo static > "${a}/usr/lib/aarch64-linux-gnu/libnccl_static.a"
  echo h > "${a}/usr/include/aarch64-linux-gnu/cudnn_v9.h"
  echo h > "${a}/usr/include/nccl.h"
}

# <function> <VAR=value>...: one copy-media-payloads.sh function in a fresh bash with that environment.
_call() { local fn="$1"; shift; env "$@" bash -c "set -euo pipefail"$'\n'"${_FNS}"$'\n'"${fn}" 2>&1; }
_run() { _call copy_cuda_payload ENABLE_NVIDIA="$1" SRCPREFIX="$2" COPY_TARGET_DIR="$3"; }

t_case "ENABLE_NVIDIA=true carries the toolkit, cuDNN, NCCL and their headers"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_SRC="$(mktemp -d)"; _DST="$(mktemp -d)"
_mk_artifact "${_SRC}"
_run true "${_SRC}" "${_DST}" >/dev/null; t_assert_eq 0 $? "a complete artifact copies cleanly"
t_assert_eq nvcc "$(cat "${_DST}/usr/local/cuda-13.3/bin/nvcc" 2>/dev/null)" "the toolkit dir is copied"
t_assert_eq rt "$(cat "${_DST}/usr/local/cuda/targets/sbsa-linux/lib/libcudart.so.13" 2>/dev/null)" \
  "/usr/local/cuda resolves INSIDE the image, not through /etc/alternatives"
t_assert_eq cuda-13.3 "$(readlink "${_DST}/usr/local/cuda-13")" "cuda-MAJOR is relinked relatively"
t_assert_eq dnn "$(cat "${_DST}/usr/lib/aarch64-linux-gnu/libcudnn.so.9" 2>/dev/null)" \
  "the cuDNN soname chain survives"
t_assert_eq nccl "$(cat "${_DST}/usr/lib/aarch64-linux-gnu/libnccl.so.2.31.2" 2>/dev/null)" "NCCL is copied"
t_assert_eq "" "$(compgen -G "${_DST}/usr/lib/aarch64-linux-gnu/*static*")" "static archives stay behind"
t_assert_eq h "$(cat "${_DST}/usr/include/aarch64-linux-gnu/cudnn_v9.h" 2>/dev/null)" "cuDNN headers are copied"
t_assert_eq yes "$([ -d "${_DST}/usr/include/nccl_device" ] && echo yes)" "NCCL's header dir is copied"

t_case "a CPU image copies nothing, and a GPU image without a toolkit is fatal"
_DST2="$(mktemp -d)"
_run false "${_SRC}" "${_DST2}" >/dev/null; t_assert_eq 0 $? "ENABLE_NVIDIA=false is a no-op"
t_assert_eq "" "$(ls -A "${_DST2}")" "and leaves the image untouched"
_EMPTY="$(mktemp -d)"; _DST3="$(mktemp -d)"
_out="$(_run true "${_EMPTY}" "${_DST3}")"; _rc=$?
t_assert_eq 1 "${_rc}" "a GPU build that lost its toolkit must not ship silently"
t_assert_contains "${_out}" "no /usr/local/cuda-X.Y" "and says what is missing"

t_case "Dockerfile.package hands the switch and the environment to the image"
t_assert_contains "$(cat "${PKG}")" $'ENABLE_NVIDIA="${ENABLE_NVIDIA:-false}" ENABLE_AMD="${ENABLE_AMD:-false}" \\\n      ENABLE_ROCM_ASAN="${ENABLE_ROCM_ASAN:-false}" ENABLE_DEEPSTREAM="${ENABLE_DEEPSTREAM:-false}" \\\n      ENABLE_TENSORRT="${ENABLE_TENSORRT:-false}" SRCPREFIX=/artifact-src bash /tmp/copy-media-payloads.sh' \
  "the payload RUN receives ENABLE_NVIDIA (an undeclared ARG reaches no RUN)"
t_assert_contains "$(cat "${PKG}")" ':/usr/local/cuda/bin:' "nvcc is on the shipped PATH"
t_assert_contains "$(cat "${PKG}")" 'NVCC_PREPEND_FLAGS=-allow-unsupported-compiler' \
  "nvcc accepts the image's GCC"
t_assert_contains "$(t_fn_src "${PAY}" copy_media_payloads)" $'\n  copy_cuda_payload\n' \
  "the payload copy actually runs it (the suite above calls it directly)"
t_assert_contains "$(cat "${PAY}")" $'  copy_media_payloads "${1:-}"\n  publish_cuda_ld_path' \
  "the toolkit's targets/<arch>/lib reaches the loader"

t_case "ENABLE_TENSORRT=true carries TensorRT's runtime .so files and licence notes, never its headers or dev links"
_TSRC="$(mktemp -d)"; _TDST="$(mktemp -d)"
_L="${_TSRC}/usr/lib/x86_64-linux-gnu"
mkdir -p "${_L}" "${_TSRC}/usr/include/x86_64-linux-gnu" "${_TSRC}/usr/share/doc/libnvinfer11" \
  "${_TSRC}/usr/share/doc/libnvinfer-dev" "${_TSRC}/usr/share/doc/tensorrt-11.4.0.106"
for f in libnvinfer.so.11.4.0 libnvinfer_plugin.so.11.4.0 libnvonnxparser.so.11.4.0 libnvinfer_lean.so.11.4.0 \
         libnvinfer_builder_resource_sm75.so.11.4.0 libnvinfer_builder_resource_ptx.so.11.4.0 libtensorrt_shim.so \
         libnvinfer_builder_resource_sm75.so.10.16.1; do echo "${f}" > "${_L}/${f}"; done
for f in libnvinfer libnvinfer_plugin libnvonnxparser libnvinfer_lean; do echo "${f}.so.11" > "${_L}/${f}.so.11"; echo dev > "${_L}/${f}.so"; done
echo h > "${_TSRC}/usr/include/x86_64-linux-gnu/NvInfer.h"
echo c > "${_TSRC}/usr/share/doc/libnvinfer11/copyright"; echo c > "${_TSRC}/usr/share/doc/libnvinfer-dev/copyright"
echo r > "${_TSRC}/usr/share/doc/tensorrt-11.4.0.106/README.txt"
_trun() { _call copy_tensorrt_payload ENABLE_TENSORRT="$1" TENSORRT_VERSION="${4:-11.4.0.106}" SRCPREFIX="$2" COPY_TARGET_DIR="$3"; }
_trun true "${_TSRC}" "${_TDST}" >/dev/null; t_assert_eq 0 $? "a TensorRT artifact copies cleanly"
_got="$(cd "${_TDST}" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
_want="libnvinfer.so.11 libnvinfer.so.11.4.0 libnvinfer_builder_resource_ptx.so.11.4.0 libnvinfer_builder_resource_sm75.so.11.4.0"
_want+=" libnvinfer_lean.so.11 libnvinfer_lean.so.11.4.0 libnvinfer_plugin.so.11 libnvinfer_plugin.so.11.4.0"
_want+=" libnvonnxparser.so.11 libnvonnxparser.so.11.4.0"
t_assert_eq "$(for f in ${_want}; do printf './usr/lib/x86_64-linux-gnu/%s ' "${f}"; done)./usr/share/doc/libnvinfer11/copyright ./usr/share/doc/tensorrt-11.4.0.106/README.txt " \
  "${_got}" "the runtime .so files of TENSORRT_VERSION's major, its README and the runtime packages' licence only"
_TDST2="$(mktemp -d)"
_trun false "${_TSRC}" "${_TDST2}" >/dev/null; t_assert_eq 0 $? "ENABLE_TENSORRT=false is a no-op"
t_assert_eq "" "$(ls -A "${_TDST2}")" "and leaves the image untouched"
_out="$(_trun true "$(mktemp -d)" "$(mktemp -d)")"; _rc=$?
t_assert_eq 1 "${_rc}" "an artifact without TensorRT is fatal when the image asks for it"
t_assert_contains "${_out}" "has no libnvinfer.so.11 (TENSORRT_VERSION=11.4.0.106)"
t_assert_eq 1 "$(_trun true "${_TSRC}" "$(mktemp -d)" 12.0.0.1 >/dev/null; echo $?)" "a pin whose major the artifact lacks is fatal"
t_assert_contains "$(t_fn_src "${PAY}" copy_media_payloads)" $'\n  copy_tensorrt_payload\n' "the payload copy runs it"

t_case "the torch pin enforcement installs from the SELECTED backend's index"
# Stubs: python3 reports the app lock's 2.13/0.28, uname says arm64, uv logs.
_PB="$(mktemp -d)"
printf '#!/usr/bin/env bash\ncase "$*" in *torchvision*) echo 0.28.0;; *) echo 2.13.0+cu130;; esac\n' > "${_PB}/python3"
printf '#!/usr/bin/env bash\necho aarch64\n' > "${_PB}/uname"
printf '#!/usr/bin/env bash\necho "uv $*"\n' > "${_PB}/uv"
chmod +x "${_PB}"/*
_ENF="$(t_fn_src "${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh" enforce_torch_version_pins)" || exit 1
_ENF+=$'\n'"$(t_fn_src "${TESTS_DIR}/../03-media/runtime/assemble-torch-app.sh" _torch_pin_gpu_index)" || exit 1
_enforce() {
  PATH="${_PB}:${PATH}" PYTORCH_VERSION=v2.14.0 TORCHVISION_VERSION=v0.29.0 \
    bash -c "${_ENF}"$'\nenforce_torch_version_pins' 2>&1
}
_out="$(PYTORCH_EXTRA=pytorch-cu130 _enforce)"
t_assert_contains "${_out}" "--index-url https://download.pytorch.org/whl/cu130" \
  "a CUDA torch stays CUDA (the CPU index swapped it back to CPU)"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e '--no-deps')" \
  "and brings its own nvidia-cudnn/nccl/triton pins along"
_out="$(PYTORCH_EXTRA=pytorch-cpu _enforce)"
t_assert_contains "${_out}" "--force-reinstall --no-deps --index-url https://download.pytorch.org/whl/cpu" \
  "the CPU path is unchanged"
_out="$(PYTORCH_EXTRA=pytorch-rocm10 PYTORCH_ROCM_INDEX=rocm7.14 _enforce)"
t_assert_contains "${_out}" "--index-url https://download.pytorch.org/whl/rocm7.14" \
  "a ROCm torch comes from the PINNED line, whatever index the app extra names"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e 'whl/cpu')" \
  "and never falls through to the CPU index"
# Unset, not inherited: the image exports PYTORCH_ROCM_INDEX.
_out="$(unset PYTORCH_ROCM_INDEX; PYTORCH_EXTRA=pytorch-rocm10 _enforce; echo "rc=$?")"
t_assert_contains "${_out}" "PYTORCH_ROCM_INDEX unset" "an unset pin fails loudly instead of guessing"
t_assert_eq "" "$(printf '%s\n' "${_out}" | grep -e 'uv pip install')" "and installs NOTHING (no quiet CPU fallback)"
t_assert_contains "${_out}" "rc=1" "with a failing exit status"
rm -rf "${_PB}"

rm -rf "${_SRC}" "${_DST}" "${_DST2}" "${_EMPTY}" "${_DST3}"
t_summary
