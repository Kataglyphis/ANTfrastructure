#!/usr/bin/env bash
# Prints the CUDA/cuDNN/TensorRT/NCCL versions; a missing part only warns unless CUDA_STACK_STRICT=1.
set -uo pipefail  # deliberately NO -e: probes below handle their own rc

_MISSING=0

_cuda_warn() {
  printf 'WARNING: %s\n' "$*" >&2
  _MISSING=1
}

export PATH="${CUDA_HOME:-/usr/local/cuda}/bin:${PATH}"

echo "--- nvcc ---"
if command -v nvcc >/dev/null 2>&1; then
  nvcc --version || _cuda_warn "nvcc present but failed to execute"
else
  _cuda_warn "nvcc not found"
fi

echo "--- cuDNN ---"
cudnn_hdr="$(find /usr -name "cudnn_version.h" 2>/dev/null | head -1 || true)"
if [ -n "${cudnn_hdr}" ]; then
  grep "CUDNN_MAJOR\|CUDNN_MINOR\|CUDNN_PATCHLEVEL" "${cudnn_hdr}" || true
else
  _cuda_warn "cuDNN version header not found"
fi

# TensorRT is optional (the Jetson lane ships none); CUDA_STACK_REQUIRE_TENSORRT=0 says so under strict mode.
echo "--- TensorRT ---"
if [ "${CUDA_STACK_REQUIRE_TENSORRT:-1}" = "1" ]; then
  trt_hdr="$(find /usr/include /usr/local/tensorrt/include -name "NvInferVersion.h" 2>/dev/null | head -1 || true)"
  if [ -n "${trt_hdr}" ]; then
    grep "NV_TENSORRT_MAJOR\|NV_TENSORRT_MINOR\|NV_TENSORRT_PATCH" "${trt_hdr}" || true
  else
    _cuda_warn "TensorRT version header not found"
  fi
else
  echo "not required here (CUDA_STACK_REQUIRE_TENSORRT=0)"
fi

echo "--- NCCL ---"
nccl_hdr="$(find /usr/include /usr/local/cuda -name "nccl.h" 2>/dev/null | head -1 || true)"
if [ -n "${nccl_hdr}" ]; then
  grep "NCCL_MAJOR\|NCCL_MINOR" "${nccl_hdr}" || true
else
  _cuda_warn "NCCL header not found"
fi

echo "--- CUDA libs ---"
cuda_libs="$(ldconfig -p 2>/dev/null | grep -E "libcublas|libcusparse|libcufft|libcudnn|libnvinfer|libnccl" | head -20 || true)"
if [ -n "${cuda_libs}" ]; then
  printf '%s\n' "${cuda_libs}"
else
  _cuda_warn "no CUDA libs found in ldconfig"
fi

# The cross target (install-cuda-stack.sh wrote cross-target.env): libs, links, staging and a device-less nvcc cross compile.
_cuda_cross_env="${CUDA_HOME:-/usr/local/cuda}/cross-target.env"
if [ -f "${_cuda_cross_env}" ]; then
  # shellcheck disable=SC1090
  source "${_cuda_cross_env}"
  echo "--- cross target ${CUDA_CROSS_TARGET_DIR} (${CUDA_CROSS_TARGET_ARCH}) ---"
  _cuda_cross_lib="${CUDA_HOME:-/usr/local/cuda}/targets/${CUDA_CROSS_TARGET_DIR}/lib"
  [ -e "${_cuda_cross_lib}/libcudart.so" ] || _cuda_warn "no libcudart.so under ${_cuda_cross_lib}"
  # The cross debs ship the math libs as link stubs and static archives; the shared runtime comes staged from the sbsa repo.
  [ -e "${_cuda_cross_lib}/stubs/libcublas.so" ] && [ -e "${_cuda_cross_lib}/stubs/libnppc.so" ] || _cuda_warn "no cuBLAS/NPP link stubs under ${_cuda_cross_lib}/stubs (what -lcublas -lnppc resolve to when cross-compiling)"
  [ -n "$(find "${CUDA_CROSS_TARGET_STAGING}/usr/local" -name 'libcublas.so.*' -type f 2>/dev/null | head -1)" ] || _cuda_warn "no staged libcublas.so.* runtime under ${CUDA_CROSS_TARGET_STAGING} (the image ships the sbsa repo's runtime, not the stubs)"
  [ -e "/usr/lib/${CUDA_CROSS_TARGET_TRIPLET}/libcudnn.so.9" ] || _cuda_warn "no libcudnn.so.9 link under /usr/lib/${CUDA_CROSS_TARGET_TRIPLET}"
  [ -e "/usr/include/${CUDA_CROSS_TARGET_TRIPLET}/cudnn.h" ] || _cuda_warn "no cudnn.h link under /usr/include/${CUDA_CROSS_TARGET_TRIPLET}"
  [ -e "${CUDA_CROSS_TARGET_STAGING}/usr/lib/${CUDA_CROSS_TARGET_TRIPLET}/libnccl.so.2" ] || _cuda_warn "no staged libnccl.so.2 under ${CUDA_CROSS_TARGET_STAGING}"
  [ -n "$(find "${CUDA_CROSS_TARGET_STAGING}/usr/local" -maxdepth 3 -path '*/bin/nvcc' -type f 2>/dev/null | head -1)" ] || _cuda_warn "no staged target nvcc under ${CUDA_CROSS_TARGET_STAGING}"
  if [ "${CUDA_STACK_REQUIRE_TENSORRT:-1}" = "1" ]; then
    [ -e "/usr/local/tensorrt-${CUDA_CROSS_TARGET_DIR}/include/NvInfer.h" ] || _cuda_warn "no cross TensorRT farm at /usr/local/tensorrt-${CUDA_CROSS_TARGET_DIR}"
  fi
  _cuda_cross_cxx="${CUDA_CROSS_TARGET_TRIPLET}-g++"
  if command -v "${_cuda_cross_cxx}" >/dev/null 2>&1; then
    _cuda_cross_tmp="$(mktemp -d)"
    printf '__global__ void k(float *p) { p[threadIdx.x] *= 2.0f; }\nint main() { return 0; }\n' > "${_cuda_cross_tmp}/t.cu"
    if nvcc -allow-unsupported-compiler -ccbin "${_cuda_cross_cxx}" "--target-directory=${CUDA_CROSS_TARGET_DIR}" -c "${_cuda_cross_tmp}/t.cu" -o "${_cuda_cross_tmp}/t.o" \
       && readelf -h "${_cuda_cross_tmp}/t.o" | grep -q 'AArch64'; then
      echo "nvcc cross compile (-ccbin ${_cuda_cross_cxx} --target-directory=${CUDA_CROSS_TARGET_DIR}): AArch64 object"
    else
      _cuda_warn "nvcc could not cross-compile a kernel for ${CUDA_CROSS_TARGET_DIR} with ${_cuda_cross_cxx}"
    fi
    rm -rf "${_cuda_cross_tmp}"
  else
    _cuda_warn "no ${_cuda_cross_cxx} on PATH for the nvcc cross check"
  fi
fi

if [ "${_MISSING}" -eq 1 ] && [ "${CUDA_STACK_STRICT:-0}" = "1" ]; then
  printf 'ERROR: CUDA stack incomplete (CUDA_STACK_STRICT=1)\n' >&2
  exit 1
fi
echo "NVIDIA layer build complete."
