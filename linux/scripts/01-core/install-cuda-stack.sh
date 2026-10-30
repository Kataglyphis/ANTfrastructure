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

# Cross target: NVIDIA's cross-linux-sbsa set. docs/linux-accelerator-images.md#nvidia-on-arm64-sbsa-one-image-for-servers-and-jetson
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

# The cross cuDNN deb ships only libcudnn*.so.9.X.Y and cudnn*_v9.h; the soname/dev links and plain headers come from -dev, which has no cross variant.
cuda_cross_cudnn_links() {
  local triplet="$1" f base n=0
  for f in /usr/lib/"${triplet}"/libcudnn*.so.9.*; do
    [ -f "${f}" ] || continue
    base="${f%%.so.*}"
    ln -sfn "$(basename "${f}")" "${base}.so.9"
    ln -sfn "$(basename "${base}").so.9" "${base}.so"
    n=$((n + 1))
  done
  for f in /usr/include/"${triplet}"/cudnn*_v9.h; do
    [ -f "${f}" ] || continue
    ln -sfn "$(basename "${f}")" "${f%_v9.h}.h"
  done
  [ "${n}" -gt 0 ] || { echo "ERROR: no libcudnn*.so.9.* under /usr/lib/${triplet} after the cross cuDNN install" >&2; return 1; }
  [ -e "/usr/include/${triplet}/cudnn.h" ] || { echo "ERROR: no cudnn_v9.h under /usr/include/${triplet} to link cudnn.h to" >&2; return 1; }
  # ORT (CUDNN_PATH), OpenCV (CUDNN_LIBRARY) and TVM (USE_CUDNN=<dir>) each take one cuDNN root with include/ and lib/.
  mkdir -p "/usr/local/cudnn-${2}/include" "/usr/local/cudnn-${2}/lib"
  ln -sfn /usr/include/"${triplet}"/cudnn*.h "/usr/local/cudnn-${2}/include/"
  ln -sfn /usr/lib/"${triplet}"/libcudnn*.so* "/usr/local/cudnn-${2}/lib/"
  echo "cross cuDNN: ${n} libraries got their .so.9 and .so links; cudnn*.h -> cudnn*_v9.h under /usr/include/${triplet}; root /usr/local/cudnn-${2}"
}

# <target lib dir>: the few shared libs the cross debs ship (cudart, cupti, nvrtc, nvblas) get the unversioned dev link where it is missing.
cuda_cross_dev_links() {
  local f base n=0
  for f in "$1"/lib*.so.[0-9]*; do
    [ -e "${f}" ] || continue
    base="${f%%.so.*}"
    [ -e "${base}.so" ] || { ln -s "$(basename "${f}")" "${base}.so"; n=$((n + 1)); }
  done
  echo "cross CUDA dev links: ${n} lib*.so -> lib*.so.N links added under $1"
}

# The target's runtime: the cross debs carry the math libraries as stubs and static archives only, so what the image ships comes from the sbsa repo's own debs.
cuda_cross_target_runtime_packages() {
  local mm="$1" p
  for p in cuda-cudart cuda-nvrtc cuda-nvtx cuda-cupti libcublas libcufft libcurand libcusolver libcusparse libnpp libnvjpeg libnvjitlink libnvfatbin \
           cuda-nvcc cuda-crt libnvvm libnvptxcompiler; do
    printf '%s-%s\n' "${p}" "${mm}"
  done
  printf '%s\n' libnccl2 libnccl-dev
}

# <arch> <triplet> <staging root>: the target's own debs (runtime libs, NCCL, nvcc) are unpacked into a staging root the package stage copies.
cuda_cross_stage_target_debs() {
  local arch="$1" triplet="$2" root="$3" pkg host_ver deb_ver deb tmp
  local -a names
  mapfile -t names < <(cuda_cross_target_runtime_packages "${CUDA_VERSION_MAJOR_MINOR}")
  : "${UBUNTU_VERSION:?UBUNTU_VERSION must be set to name the NVIDIA sbsa repo}"
  printf 'deb [arch=%s signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu%s/sbsa/ /\n' \
    "${arch}" "${UBUNTU_VERSION//./}" > "/etc/apt/sources.list.d/cuda-target-${arch}.list"
  apt-get update -qq
  tmp="$(mktemp -d)"
  mkdir -p "${root}"
  for pkg in "${names[@]}"; do
    # The target's copy must be the host's version: one CUDA, two architectures.
    host_ver="$(dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null)" || { echo "ERROR: ${pkg} is not installed on the host, so its target version is unknown" >&2; return 1; }
    (cd "${tmp}" && apt-get download "${pkg}:${arch}=${host_ver}") || { echo "ERROR: no ${pkg}:${arch} at ${host_ver} in the sbsa repo" >&2; return 1; }
    deb="$(find "${tmp}" -maxdepth 1 -name "${pkg}_*_${arch}.deb" -print -quit)"
    [ -n "${deb}" ] || { echo "ERROR: apt-get download left no ${pkg}_*_${arch}.deb" >&2; return 1; }
    deb_ver="$(dpkg-deb -f "${deb}" Version)"
    [ "${deb_ver}" = "${host_ver}" ] || { echo "ERROR: ${pkg}:${arch} is ${deb_ver}, the host has ${host_ver}" >&2; return 1; }
    dpkg-deb -x "${deb}" "${root}"
    rm -f "${deb}"
  done
  rmdir "${tmp}"
  [ -x "${root}/usr/local/cuda-${CUDA_VER_DOT}/bin/nvcc" ] || { echo "ERROR: ${root} has no usr/local/cuda-${CUDA_VER_DOT}/bin/nvcc after unpacking" >&2; return 1; }
  echo "cross target staging: ${names[*]} (${arch}, host versions) unpacked into ${root}"
}

# <triplet> <staging root> <target dir>: the target's libraries and staged tools, NUL-separated.
_cuda_cross_elf_files() {
  find "/usr/local/cuda-${CUDA_VER_DOT}/targets/${3}/lib" "${2}" \
    \( -name 'lib*.so*' -o -name nvcc -o -name ptxas -o -name cicc -o -name nvlink \) -type f -print0 2>/dev/null
  # The multiarch dir also holds host tools' plugins (binutils' bfd-plugins/libdep.so is x86-64), so only the GPU libs are judged there.
  find "/usr/lib/${1}" -maxdepth 1 \( -name 'libcudnn*.so*' -o -name 'libnvinfer*.so*' -o -name 'libnvonnxparser*.so*' -o -name 'libnccl*.so*' \) -type f -print0 2>/dev/null
}

# <file>: 0 when the ELF header says AArch64; prints the file otherwise, so the gate can name it.
_cuda_elf_not_aarch64() {
  readelf -h "$1" 2>/dev/null | grep -q '^[[:space:]]*Machine:.*AArch64' || printf '%s\n' "$1"
}

# <triplet> <staging root> <target dir>: every target ELF must be AArch64, or an x86-64 .so surfaces hours later inside the arm64 image.
cuda_cross_elf_gate() {
  local n bad
  n="$(_cuda_cross_elf_files "$@" | xargs -0 -r readelf -h 2>/dev/null | grep -c '^[[:space:]]*Machine:')"
  export -f _cuda_elf_not_aarch64
  bad="$(_cuda_cross_elf_files "$@" | xargs -0 -r -n 1 bash -c '_cuda_elf_not_aarch64 "$1"' _)"
  [ -z "${bad}" ] || { printf 'ERROR: not AArch64:\n%s\n' "${bad}" >&2; return 1; }
  [ "${n}" -gt 0 ] || { echo "ERROR: the cross ELF gate found nothing to check" >&2; return 1; }
  echo "cross ELF gate: ${n} target ELF files, all AArch64"
}

if [ -n "${CUDA_CROSS_TARGET_DIR:-}" ]; then
  : "${TARGET_ARCH:?TARGET_ARCH names the cross target}"
  # shellcheck source=platform.sh
  source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"
  _cuda_cross_triplet="$(arch_deb_multiarch_triplet_for "${TARGET_ARCH}")"
  _cuda_cross_root="/opt/cuda-target/${TARGET_ARCH}"
  mapfile -t _cuda_cross_pkgs < <(cuda_cross_packages "${CUDA_VERSION_MAJOR_MINOR}" "${CUDA_MAJOR}")
  # The host headers ORT probes and the target libs it links must be one cuDNN.
  [ -z "${CUDNN_VERSION:-}" ] || _cuda_cross_pkgs=("${_cuda_cross_pkgs[@]/libcudnn9-cross-sbsa-cuda-${CUDA_MAJOR}/libcudnn9-cross-sbsa-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*}")
  echo "Installing the CUDA cross target set for ${CUDA_CROSS_TARGET_DIR}: ${_cuda_cross_pkgs[*]}"
  apt-get install -y --no-install-recommends "${_cuda_cross_pkgs[@]}"
  cuda_cross_cudnn_links "${_cuda_cross_triplet}" "${CUDA_CROSS_TARGET_DIR}"
  cuda_cross_dev_links "/usr/local/cuda-${CUDA_VER_DOT}/targets/${CUDA_CROSS_TARGET_DIR}/lib"
  echo "NOTE: NCCL has no cross package; the target's own libnccl and nvcc debs are staged under ${_cuda_cross_root} for the package stage"
  cuda_cross_stage_target_debs "${TARGET_ARCH}" "${_cuda_cross_triplet}" "${_cuda_cross_root}"
  _cuda_cross_probe="$(find "/usr/local/cuda-${CUDA_VER_DOT}/targets/${CUDA_CROSS_TARGET_DIR}/lib" -name 'libcudart.so*' -type f 2>/dev/null | head -1)"
  [ -n "${_cuda_cross_probe}" ] || { echo "ERROR: no libcudart under targets/${CUDA_CROSS_TARGET_DIR} after the cross install" >&2; exit 1; }
  case "$(readelf -h "${_cuda_cross_probe}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')" in
    *AArch64*) echo "cross CUDA verified: $(basename "${_cuda_cross_probe}") is AArch64" ;;
    *) echo "ERROR: ${_cuda_cross_probe} is not AArch64 — the cross repo served host packages" >&2; exit 1 ;;
  esac
  cuda_cross_elf_gate "${_cuda_cross_triplet}" "${_cuda_cross_root}" "${CUDA_CROSS_TARGET_DIR}"
  # What later RUNs and stages read instead of re-deriving the target: install-tensorrt.sh, verify-cuda-stack.sh, the package stage.
  _cuda_cross_tgt="/usr/local/cuda-${CUDA_VER_DOT}/targets/${CUDA_CROSS_TARGET_DIR}"
  [ -e "${_cuda_cross_tgt}/lib/stubs/libcuda.so" ] || { echo "ERROR: no driver stub at ${_cuda_cross_tgt}/lib/stubs/libcuda.so" >&2; exit 1; }
  printf 'CUDA_CROSS_TARGET_DIR=%s\nCUDA_CROSS_TARGET_ARCH=%s\nCUDA_CROSS_TARGET_TRIPLET=%s\nCUDA_CROSS_TARGET_STAGING=%s\nCUDA_CROSS_TARGET_ROOT=%s\nCUDA_CROSS_STUB_LIBCUDA=%s\nCUDA_CROSS_CUDNN_HOME=%s\nCUDA_CROSS_TENSORRT_HOME=%s\n' \
    "${CUDA_CROSS_TARGET_DIR}" "${TARGET_ARCH}" "${_cuda_cross_triplet}" "${_cuda_cross_root}" "${_cuda_cross_tgt}" "${_cuda_cross_tgt}/lib/stubs/libcuda.so" \
    "/usr/local/cudnn-${CUDA_CROSS_TARGET_DIR}" "/usr/local/tensorrt-${CUDA_CROSS_TARGET_DIR}" > "/usr/local/cuda-${CUDA_VER_DOT}/cross-target.env"
fi
# An empty CUDNN_VERSION skips the pinned tier; -dev depends on the exact headers package, so it is pinned too.
{ [ -n "${CUDNN_VERSION:-}" ] && \
apt-get install -y --no-install-recommends \
    "libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" \
    "libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*" \
    "libcudnn${CUDNN_MAJOR}-headers-cuda-${CUDA_MAJOR}=${CUDNN_VERSION}*"; } || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_VER_DOT} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_VER_DOT} || \
apt-get install -y --no-install-recommends \
    libcudnn${CUDNN_MAJOR}-cuda-${CUDA_MAJOR} \
    libcudnn${CUDNN_MAJOR}-dev-cuda-${CUDA_MAJOR} || \
echo "WARNING: cuDNN packages not found; continuing without cuDNN"
# Keep the CUDA repo and apt lists (a shared cache mount): the TensorRT RUN still installs from them.
ldconfig
