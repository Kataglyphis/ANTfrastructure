#!/usr/bin/env bash
# CUDA + cuDNN after setup-cuda-repo.sh; env CUDA_VERSION_MAJOR_MINOR (12-6), CUDNN_MAJOR, optional CUDNN_VERSION.
set -euo pipefail

CUDA_MAJOR="$(echo "${CUDA_VERSION_MAJOR_MINOR}" | cut -d'-' -f1)"

# cuda-compat is the datacenter forward-compat driver; on Jetson it shadows the L4T libcuda (CUDA_INSTALL_COMPAT=0).
_cuda_compat_pkgs=()
if [ "${CUDA_INSTALL_COMPAT:-1}" = "1" ]; then
  _cuda_compat_pkgs+=("cuda-compat-${CUDA_VERSION_MAJOR_MINOR}")
else
  echo "CUDA_INSTALL_COMPAT=0 — skipping cuda-compat-${CUDA_VERSION_MAJOR_MINOR} (Tegra/Jetson: the driver comes from the L4T BSP)"
fi

apt-get install -y --no-install-recommends \
    cuda-toolkit-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-libraries-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-libraries-dev-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-nvtx-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-command-line-tools-${CUDA_VERSION_MAJOR_MINOR} \
    libnccl2 \
    libnccl-dev \
    libcublas-${CUDA_VERSION_MAJOR_MINOR} \
    libcublas-dev-${CUDA_VERSION_MAJOR_MINOR} \
    libcusparse-${CUDA_VERSION_MAJOR_MINOR} \
    libcusparse-dev-${CUDA_VERSION_MAJOR_MINOR} \
    libcufft-${CUDA_VERSION_MAJOR_MINOR} \
    libcufft-dev-${CUDA_VERSION_MAJOR_MINOR} \
    cuda-cudart-dev-${CUDA_VERSION_MAJOR_MINOR} \
    "${_cuda_compat_pkgs[@]}"
CUDA_VER_DOT="$(echo "${CUDA_VERSION_MAJOR_MINOR}" | tr '-' '.')"

# Cross target: sbsa libs only, no NCCL. docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson
cuda_cross_packages() {
  local mm="$1" cuda_major="$2"
  [ -n "${mm}" ] && [ -n "${cuda_major}" ] || return 1
  printf '%s\n' \
    "cuda-cross-sbsa-${mm}" \
    "libcublas-cross-sbsa-${mm}" \
    "libcufft-cross-sbsa-${mm}" \
    "libcusparse-cross-sbsa-${mm}" \
    "libcurand-cross-sbsa-${mm}" \
    "libcusolver-cross-sbsa-${mm}" \
    "libnpp-cross-sbsa-${mm}" \
    "libcudnn9-cross-sbsa-cuda-${cuda_major}"
}

if [ -n "${CUDA_CROSS_TARGET_DIR:-}" ]; then
  mapfile -t _cuda_cross_pkgs < <(cuda_cross_packages "${CUDA_VERSION_MAJOR_MINOR}" "${CUDA_MAJOR}")
  echo "Installing the CUDA cross target set for ${CUDA_CROSS_TARGET_DIR}: ${_cuda_cross_pkgs[*]}"
  apt-get install -y --no-install-recommends "${_cuda_cross_pkgs[@]}"
  echo "NOTE: NCCL has no cross package; this target ships without libnccl (single-GPU CUDA EP and torch are unaffected)"
  # The target libs must be foreign, or an x86-64 .so surfaces hours later inside the arm64 image.
  _cuda_cross_probe="$(find "/usr/local/cuda-${CUDA_VER_DOT}/targets/${CUDA_CROSS_TARGET_DIR}/lib" \
      "/usr/local/cuda/targets/${CUDA_CROSS_TARGET_DIR}/lib" -name 'libcudart.so*' -type f 2>/dev/null | head -1)"
  [ -n "${_cuda_cross_probe}" ] || { echo "ERROR: no libcudart under targets/${CUDA_CROSS_TARGET_DIR} after the cross install" >&2; exit 1; }
  case "$(readelf -h "${_cuda_cross_probe}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')" in
    *AArch64*) echo "cross CUDA verified: $(basename "${_cuda_cross_probe}") is AArch64" ;;
    *) echo "ERROR: ${_cuda_cross_probe} is not AArch64 — the cross repo served host packages" >&2; exit 1 ;;
  esac
fi
# An empty CUDNN_VERSION skips the pinned tier.
{ [ -n "${CUDNN_VERSION:-}" ] && \
apt-get install -y --no-install-recommends \
    "libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" \
    "libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*"; } || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_VER_DOT} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_VER_DOT} || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR} || \
echo "WARNING: cuDNN packages not found; continuing without cuDNN"
# Keep the CUDA repo and apt lists (a shared cache mount): the TensorRT RUN still installs from them.
ldconfig
