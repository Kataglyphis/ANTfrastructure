#!/usr/bin/env bash
set -euo pipefail

# copy-media-payloads.sh
# Shared helper to copy lightweight media library payloads (LiteRT, VVdec,
# ONNX Runtime GenAI/GPU, and CUDA/cuDNN/NCCL when ENABLE_NVIDIA=true) from the
# artifact image into the package image.
#
# Usage:
#   copy-media-payloads.sh              Copy onto the local filesystem.
#   copy-media-payloads.sh /payload     Copy into a staging prefix.
#   SRCPREFIX=/runtime_artifact \
#     copy-media-payloads.sh            Copy from a bind-mounted source prefix.

SRCPREFIX="${SRCPREFIX:-}"

# This script historically called warn without defining it (it was never
# invoked anywhere, so the bug was latent). Provide a fallback.
if ! command -v warn >/dev/null 2>&1; then
  warn() { printf '[WARN] %s\n' "$*" >&2; }
fi

_dest() {
  local rel="${1:-}"
  local target_dir="${COPY_TARGET_DIR:-}"
  printf '%s' "${target_dir}${rel}"
}

copy_path() {
  local src="${SRCPREFIX}$1"
  local dst
  dst="$(_dest "${2:-$1}")"
  if [ ! -e "${src}" ]; then
    warn "copy-media-payloads: optional payload missing: ${src}"
    return 0
  fi
  mkdir -p "$(dirname "${dst}")"
  # -T: treat dst as the exact destination — plain cp -a into an existing
  # directory would NEST (dst/srcname) instead of overlaying.
  cp -aT "${src}" "${dst}"
}

copy_glob() {
  local pattern="${SRCPREFIX}$1"
  local item rel dst
  shopt -s nullglob
  for item in ${pattern}; do
    rel="${item#${SRCPREFIX}}"
    dst="$(_dest "${rel}")"
    mkdir -p "$(dirname "${dst}")"
    cp -a "${item}" "${dst}"
  done
  shopt -u nullglob
}

copy_media_payloads() {
  local target_dir="${1:-}"
  export COPY_TARGET_DIR="${target_dir}"

  for path in \
    /usr/local/lib/onnxruntime-genai \
    /usr/local/lib/onnxruntime-gpu \
    /usr/local/include/tflite \
    /usr/local/include/absl \
    /usr/local/include/tensorflow \
    /usr/local/include/flatbuffers \
    /usr/local/include/c \
    /usr/local/lib/pkgconfig/litert.pc \
    /usr/local/lib/pkgconfig/tensorflow-lite.pc \
    /usr/local/lib/pkgconfig/tensorflowlite_c.pc \
    /usr/local/lib/pkgconfig/libvvdec.pc \
    /usr/local/lib/litert-web \
    /usr/local/lib/litert-lm-web \
    /usr/local/lib/onnxruntime-web; do
    # (llvm-target is COPY'd explicitly by Dockerfile.package; not repeated here)
    copy_path "${path}"
  done

  for pattern in \
    '/usr/local/lib/libLiteRt.so*' \
    '/usr/local/lib/libtensorflow-lite.so*' \
    '/usr/local/lib/libtensorflowlite_c.so*' \
    '/usr/local/lib/libvvdec.so*' \
    '/usr/local/lib/libtvm.so*' \
    '/usr/local/lib/libtvm_runtime.so*' \
    '/usr/local/lib/libtvm_runtime_cuda.so*' \
    '/usr/local/lib/libtvm_compiler.so*'; do
    copy_glob "${pattern}"
  done

  copy_cuda_payload
  copy_rocm_payload

  unset COPY_TARGET_DIR
}

# The GPU variant's CUDA toolkit, cuDNN and NCCL. The media image carries them,
# but nothing copied them past this boundary: every CUDA-built library (OpenCV,
# ORT's CUDA EP, TVM's CUDA runtime) shipped without libcudart/libcudnn and
# could not load. ENABLE_NVIDIA=true with no toolkit in the artifact is fatal.
copy_cuda_payload() {
  [ "${ENABLE_NVIDIA:-false}" = "true" ] || return 0
  local dir ver="" pattern
  shopt -s nullglob
  for dir in "${SRCPREFIX}"/usr/local/cuda-[0-9]*.[0-9]*; do
    ver="${dir##*/cuda-}"
    copy_path "/usr/local/cuda-${ver}"
  done
  shopt -u nullglob
  if [ -z "${ver}" ]; then
    printf '[ERROR] ENABLE_NVIDIA=true but the artifact has no /usr/local/cuda-X.Y\n' >&2
    return 1
  fi
  # The artifact's cuda and cuda-MAJOR links go through /etc/alternatives, which
  # through a bind mount resolves against the BUILD container. Relink relatively.
  ln -sfn "cuda-${ver}" "$(_dest /usr/local/cuda)"
  ln -sfn "cuda-${ver}" "$(_dest "/usr/local/cuda-${ver%%.*}")"
  for pattern in \
    '/usr/lib/*-linux-gnu/libcudnn*.so*' \
    '/usr/lib/*-linux-gnu/libnccl.so*' \
    '/usr/include/*-linux-gnu/cudnn*.h' \
    '/usr/include/nccl*'; do
    copy_glob "${pattern}"
  done
}

# Where an artifact path really lands, resolved as the SHIPPED image will see it:
# every hop of a link is re-read under SRCPREFIX, because through the bind mount
# an absolute target (/etc/alternatives/...) resolves in the BUILD container.
_src_resolve() {
  local p="$1" t hops=0
  while [ -L "${SRCPREFIX}${p}" ]; do
    hops=$((hops + 1)); [ "${hops}" -le 40 ] || return 1
    t="$(readlink "${SRCPREFIX}${p}")"
    case "${t}" in /*) p="${t}" ;; *) p="$(dirname "${p}")/${t}" ;; esac
    p="$(realpath -m -s "${p}")"
  done
  printf '%s' "${p}"
}

# The rocm variant's ROCm/MIGraphX userspace (HIP, MIOpen, rocBLAS, MIGraphX),
# the same gap copy_cuda_payload closes for CUDA: the ORT MIGraphX EP and a ROCm
# torch load these at runtime, and nothing copied /opt/rocm past this boundary.
# TheRock (Dockerfile.amd) makes /opt/rocm a real directory whose `core` is an
# update-alternatives link (/etc/alternatives/... -> /opt/rocm/core-X.Y) and
# whose bin/include/lib point at core/ (setup-rocm-repo.sh); older releases made
# /opt/rocm itself such a link. cp -a keeps links verbatim, so every ABSOLUTE
# link in the copied tree is re-made relative to its real artifact target, and
# a target outside the tree is copied too. ENABLE_AMD=true without a usable
# /opt/rocm/lib (libamdhip64) in the result is fatal.
copy_rocm_payload() {
  [ "${ENABLE_AMD:-false}" = "true" ] || return 0
  local root link img t real
  root="$(_src_resolve /opt/rocm)" || { printf '[ERROR] /opt/rocm is a link loop in the artifact\n' >&2; return 1; }
  if [ ! -d "${SRCPREFIX}${root}" ]; then
    printf '[ERROR] ENABLE_AMD=true but the artifact has no /opt/rocm\n' >&2
    return 1
  fi
  copy_path "${root}"
  # The ASAN tree lives INSIDE /opt/rocm (core-asan-<ver>) and is ~135 GiB, so
  # the default image drops it even when the builder installed it.
  if [ "${ENABLE_ROCM_ASAN:-false}" != "true" ]; then
    rm -rf "$(_dest "${root}")"/core-asan-* 2>/dev/null || true
  fi
  [ "${root}" = /opt/rocm ] \
    || ln -sfn "$(realpath -m -s --relative-to=/opt "${root}")" "$(_dest /opt/rocm)"
  while IFS= read -r -d '' link; do
    t="$(readlink "${link}")"
    case "${t}" in /*) ;; *) continue ;; esac
    img="${link#"$(_dest "")"}"
    real="$(_src_resolve "${img}")" || continue
    [ -e "${SRCPREFIX}${real}" ] || continue
    case "${real}" in "${root}"|"${root}"/*) ;; *) copy_path "${real}" ;; esac
    ln -sfn "$(realpath -m -s --relative-to="$(dirname "${img}")" "${real}")" "${link}"
  done < <(find "$(_dest "${root}")" -type l -print0)
  if ! compgen -G "$(_dest /opt/rocm)/lib/libamdhip64.so*" >/dev/null; then
    printf '[ERROR] ENABLE_AMD=true but /opt/rocm/lib in the package has no libamdhip64 (links unresolved?)\n' >&2
    return 1
  fi
}

# The toolkit's libs live under targets/<arch>-linux/lib, which no default
# loader path reaches. No-op on a CPU image, where /usr/local/cuda is absent.
publish_cuda_ld_path() {
  local lib
  : > /etc/ld.so.conf.d/000-cuda.conf
  for lib in /usr/local/cuda/targets/*/lib; do
    [ -d "${lib}" ] && printf '%s\n' "${lib}" >> /etc/ld.so.conf.d/000-cuda.conf
  done
  [ -s /etc/ld.so.conf.d/000-cuda.conf ] || rm -f /etc/ld.so.conf.d/000-cuda.conf
}

# ROCm's libraries live under /opt/rocm/lib (-> core/lib -> core-X.Y/lib),
# which no default loader path reaches. No-op without /opt/rocm.
publish_rocm_ld_path() {
  local lib
  : > /etc/ld.so.conf.d/000-rocm.conf
  for lib in /opt/rocm/lib /opt/rocm/lib64; do
    [ -d "${lib}" ] && printf '%s\n' "${lib}" >> /etc/ld.so.conf.d/000-rocm.conf
  done
  [ -s /etc/ld.so.conf.d/000-rocm.conf ] || rm -f /etc/ld.so.conf.d/000-rocm.conf
}

# Give /usr/local/llvm-target/lib loader priority over the distro multiarch dir:
# libtvm_compiler.so's DT_NEEDED libLLVM.so.<ver> resolves through this and nothing
# else, so `import tvm` dies without it.
# docs/artifact-copy-completeness.md#the-llvm-target-prefix-fills-what-it-needs-and-nothing-else
publish_llvm_target_ld_path() {
  printf '/usr/local/llvm-target/lib\n' > /etc/ld.so.conf.d/000-llvm-target.conf
  ldconfig
}

main() {
  copy_media_payloads "${1:-}"
  publish_cuda_ld_path
  publish_rocm_ld_path
  publish_llvm_target_ld_path
}

main "$@"
