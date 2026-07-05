#!/usr/bin/env bash
# verify-cuda-stack.sh - non-fatal verification banner for the installed CUDA /
# cuDNN / TensorRT / NCCL stack. Prints versions and warns (does not fail) on
# anything missing. Extracted verbatim from the verification RUN in
# linux/Dockerfile.nvidia.
#
# Environment:
#   CUDA_HOME   canonical CUDA install (default /usr/local/cuda)
set -euo pipefail

export PATH="${CUDA_HOME:-/usr/local/cuda}/bin:${PATH}"
command -v nvcc >/dev/null 2>&1 && nvcc --version || echo "WARNING: nvcc not found"
echo "--- cuDNN ---"
cudnn_hdr="$(find /usr -name "cudnn_version.h" 2>/dev/null | head -1)"
if [ -n "${cudnn_hdr}" ]; then
    grep "CUDNN_MAJOR\|CUDNN_MINOR\|CUDNN_PATCHLEVEL" "${cudnn_hdr}"
else
    echo "WARNING: cuDNN version header not found"
fi
echo "--- TensorRT ---"
trt_hdr="$(find /usr/include /usr/local/tensorrt/include -name "NvInferVersion.h" 2>/dev/null | head -1)"
if [ -n "${trt_hdr}" ]; then
    grep "NV_TENSORRT_MAJOR\|NV_TENSORRT_MINOR\|NV_TENSORRT_PATCH" "${trt_hdr}"
else
    echo "WARNING: TensorRT version header not found"
fi
echo "--- NCCL ---"
nccl_hdr="$(find /usr/include /usr/local/cuda -name "nccl.h" 2>/dev/null | head -1)"
if [ -n "${nccl_hdr}" ]; then
    grep "NCCL_MAJOR\|NCCL_MINOR" "${nccl_hdr}"
else
    echo "WARNING: NCCL header not found" >&2
fi
echo "--- CUDA libs ---"
ldconfig -p | grep -E "libcublas|libcusparse|libcufft|libcudnn|libnvinfer|libnccl" 2>/dev/null | head -20 || echo "WARNING: no CUDA libs found in ldconfig"
echo "NVIDIA layer build complete."
