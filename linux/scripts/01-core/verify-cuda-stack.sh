#!/usr/bin/env bash
# verify-cuda-stack.sh - verification banner for the installed CUDA / cuDNN /
# TensorRT / NCCL stack. Prints versions; missing components WARN (stderr).
#
# Default contract is warn-only (the accelerator layer is opt-in and partial
# installs are legitimate during bring-up). Set CUDA_STACK_STRICT=1 to turn
# every missing component into a hard failure — the real gate for images that
# claim a complete CUDA stack.
#
# History: the original version had ` || true)` pasted INSIDE three command
# substitutions, so the "not found" branches were unreachable (the variable
# always contained the literal string ` || true)`) and, under the then-active
# `set -e`, grep against that garbage filename hard-failed healthy images.
# The warn-only contract this file claims never actually existed until the
# 2026-08-08 rewrite.
#
# Environment:
#   CUDA_HOME          canonical CUDA install (default /usr/local/cuda)
#   CUDA_STACK_STRICT  1 = missing components fail the script (default 0)
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

echo "--- TensorRT ---"
trt_hdr="$(find /usr/include /usr/local/tensorrt/include -name "NvInferVersion.h" 2>/dev/null | head -1 || true)"
if [ -n "${trt_hdr}" ]; then
  grep "NV_TENSORRT_MAJOR\|NV_TENSORRT_MINOR\|NV_TENSORRT_PATCH" "${trt_hdr}" || true
else
  _cuda_warn "TensorRT version header not found"
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

if [ "${_MISSING}" -eq 1 ] && [ "${CUDA_STACK_STRICT:-0}" = "1" ]; then
  printf 'ERROR: CUDA stack incomplete (CUDA_STACK_STRICT=1)\n' >&2
  exit 1
fi
echo "NVIDIA layer build complete."
