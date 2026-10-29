#!/usr/bin/env bash
set -euo pipefail

# Usage: [SRCPREFIX=<artifact mount>] copy-media-payloads.sh [dest-prefix]

# shellcheck source=media-payloads.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/media-payloads.sh"

SRCPREFIX="${SRCPREFIX:-}"

_payload_logger="$(dirname "${BASH_SOURCE[0]}")/log-bootstrap.sh"
[ -f "${_payload_logger}" ] || _payload_logger="$(dirname "${BASH_SOURCE[0]}")/../lib/log-bootstrap.sh"
# shellcheck source=../lib/log-bootstrap.sh
_LOG_BOOTSTRAP_REGISTRAR_ONLY=1 source "${_payload_logger}"
unset _payload_logger
log_bootstrap_fallbacks command plain warn

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
  # -T: cp -a into an existing directory would nest instead of overlay.
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
  local target_dir="${1:-}" _observation
  export COPY_TARGET_DIR="${target_dir}"

  while IFS='|' read -r path _observation; do
    copy_path "${path}"
  done < <(media_optional_payloads)

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
  copy_tensorrt_payload
  copy_rocm_payload
  copy_deepstream_payload

  unset COPY_TARGET_DIR
}

# The multiarch dir of the GPU libraries the image ships: the target's under a cross build, else every one the artifact has.
_cuda_payload_multiarch() {
  printf '%s' "${CUDA_CROSS_TARGET_TRIPLET:-*-linux-gnu}"
}

# <ver>: true when the gpu stage cross-built the toolkit for THIS image's arch, with its cross-target.env loaded (CUDA_CROSS_*).
cuda_payload_cross() {
  local f="${SRCPREFIX}/usr/local/cuda-$1/cross-target.env"
  [ -f "${f}" ] || return 1
  # shellcheck disable=SC1090 # the gpu stage wrote it
  source "${f}"
  [ "${CUDA_CROSS_TARGET_ARCH:-}" = "${TARGET_ARCH:-}" ] && return 0
  unset CUDA_CROSS_TARGET_TRIPLET
  return 1
}

# <ver>: a cross target's toolkit = the cross debs' targets/<dir> (headers, stubs, static) under the sbsa repo's own debs (bin, nvvm, the shared runtime, NCCL).
copy_cuda_cross_toolkit() {
  local ver="$1" staged="${CUDA_CROSS_TARGET_STAGING}/usr/local/cuda-${ver}" item
  copy_path "/usr/local/cuda-${ver}/targets/${CUDA_CROSS_TARGET_DIR}"
  if [ ! -d "${SRCPREFIX}${staged}" ]; then
    printf '[ERROR] cross CUDA target %s but the artifact has no staged runtime under %s\n' "${CUDA_CROSS_TARGET_DIR}" "${staged}" >&2
    return 1
  fi
  copy_path "${staged}" "/usr/local/cuda-${ver}"
  for item in "${SRCPREFIX}${CUDA_CROSS_TARGET_STAGING}/usr/lib/${CUDA_CROSS_TARGET_TRIPLET}"/libnccl*.so* "${SRCPREFIX}${CUDA_CROSS_TARGET_STAGING}"/usr/include/nccl*; do
    [ -e "${item}" ] || continue
    copy_path "${item#"${SRCPREFIX}"}" "${item#"${SRCPREFIX}${CUDA_CROSS_TARGET_STAGING}"}"
  done
  echo "cross CUDA payload: ${CUDA_CROSS_TARGET_DIR} headers and stubs, the staged ${CUDA_CROSS_TARGET_ARCH} runtime, nvcc and NCCL"
}

# <ELF machine byte> <dir>...: every ELF under the dirs is the target's; a host binary in a cross image loads nowhere.
cuda_payload_arch_gate() {
  local want="$1" f h n=0 bad=0
  shift
  while IFS= read -r -d '' f; do
    h="$(od -An -tx1 -N20 "${f}" 2>/dev/null | tr -d ' \n')"
    [ "${h:0:8}" = "7f454c46" ] || continue
    n=$((n + 1))
    [ "${h:36:2}" = "${want}" ] && continue
    bad=$((bad + 1))
    [ "${bad}" -gt 3 ] || printf '[ERROR] CUDA payload: %s has ELF machine 0x%s, the image needs 0x%s\n' "${f}" "${h:36:2}" "${want}" >&2
  done < <(find "$@" -type f \( -name '*.so*' -o -perm -u+x \) -print0 2>/dev/null)
  echo "CUDA payload arch gate: ${n} ELF files, ${bad} not the target's"
  [ "${bad}" -eq 0 ]
}

# The low byte of e_machine for the image's arch.
_cuda_payload_elf_machine() {
  case "${TARGET_ARCH:-}" in arm64) printf b7 ;; amd64) printf 3e ;; riscv64) printf f3 ;; *) return 1 ;; esac
}

# Every CUDA-built library needs the toolkit, cuDNN and NCCL to load; ENABLE_NVIDIA=true without them is fatal.
copy_cuda_payload() {
  [ "${ENABLE_NVIDIA:-false}" = "true" ] || return 0
  local dir ver="" pattern cross=0 m
  shopt -s nullglob
  for dir in "${SRCPREFIX}"/usr/local/cuda-[0-9]*.[0-9]*; do
    ver="${dir##*/cuda-}"
    if cuda_payload_cross "${ver}"; then
      cross=1
      copy_cuda_cross_toolkit "${ver}" || return 1
    else
      copy_path "/usr/local/cuda-${ver}"
    fi
  done
  shopt -u nullglob
  if [ -z "${ver}" ]; then
    printf '[ERROR] ENABLE_NVIDIA=true but the artifact has no /usr/local/cuda-X.Y\n' >&2
    return 1
  fi
  # Relink relatively: through the bind mount /etc/alternatives resolves in the build container.
  ln -sfn "cuda-${ver}" "$(_dest /usr/local/cuda)"
  ln -sfn "cuda-${ver}" "$(_dest "/usr/local/cuda-${ver%%.*}")"
  m="$(_cuda_payload_multiarch)"
  for pattern in \
    "/usr/lib/${m}/libcudnn*.so*" \
    "/usr/lib/${m}/libnccl.so*" \
    "/usr/include/${m}/cudnn*.h" \
    '/usr/include/nccl*'; do
    copy_glob "${pattern}"
  done
  [ "${cross}" -eq 1 ] || return 0
  cuda_payload_arch_gate "$(_cuda_payload_elf_machine)" "$(_dest "/usr/local/cuda-${ver}")" "$(_dest "/usr/lib/${m}")"
}

# The SLA lets only TensorRT's runtime .so files ship, so headers and dev links stay behind: docs/linux-accelerator-images.md#tensorrt-11
copy_tensorrt_payload() {
  [ "${ENABLE_TENSORRT:-false}" = "true" ] || return 0
  local m="${TENSORRT_VERSION%%.*}" pattern
  if [ -z "${m}" ] || ! compgen -G "${SRCPREFIX}/usr/lib/*-linux-gnu/libnvinfer.so.${m}" >/dev/null; then
    printf '[ERROR] ENABLE_TENSORRT=true but the artifact has no libnvinfer.so.%s (TENSORRT_VERSION=%s)\n' "${m}" "${TENSORRT_VERSION:-}" >&2
    return 1
  fi
  # The multiarch dir follows copy_cuda_payload's verdict: a cross image ships the target's TensorRT, never the host's.
  local ma; ma="$(_cuda_payload_multiarch)"
  for pattern in \
    "/usr/lib/${ma}/libnvinfer*.so.${m}" "/usr/lib/${ma}/libnvinfer*.so.${m}.*" \
    "/usr/lib/${ma}/libnvonnxparser.so.${m}" "/usr/lib/${ma}/libnvonnxparser.so.${m}.*" \
    "/usr/share/doc/libnvinfer*${m}" "/usr/share/doc/libnvonnxparsers${m}*"; do
    copy_glob "${pattern}"
  done
  copy_path "/usr/share/doc/tensorrt-${TENSORRT_VERSION}"
}

# Only on request: an image built without ENABLE_DEEPSTREAM=true must not carry it, whatever its artifact holds.
copy_deepstream_payload() {
  [ "${ENABLE_DEEPSTREAM:-false}" = "true" ] || return 0
  if [ ! -d "${SRCPREFIX}/opt/nvidia/deepstream" ]; then
    printf '[ERROR] ENABLE_DEEPSTREAM=true but the artifact has no /opt/nvidia/deepstream\n' >&2
    return 1
  fi
  copy_path /opt/nvidia/deepstream
}

# Every link hop re-read under SRCPREFIX: through the bind mount an absolute target resolves in the build container.
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

# ROCm userspace; cp -a keeps /opt/rocm's alternatives links verbatim, so absolute links are remade relative.
copy_rocm_payload() {
  [ "${ENABLE_AMD:-false}" = "true" ] || return 0
  local root link img t real
  root="$(_src_resolve /opt/rocm)" || { printf '[ERROR] /opt/rocm is a link loop in the artifact\n' >&2; return 1; }
  if [ ! -d "${SRCPREFIX}${root}" ]; then
    printf '[ERROR] ENABLE_AMD=true but the artifact has no /opt/rocm\n' >&2
    return 1
  fi
  copy_path "${root}"
  # The ASAN tree inside /opt/rocm is ~135 GiB; ship it only when asked.
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
  # The whole tree, as HIP sits in core-<ver>/lib; -print -quit, since `find | grep -q` dies of SIGPIPE.
  [ -n "$(find "$(_dest /opt/rocm)" \( -type f -o -type l \) -name 'libamdhip64.so*' -print -quit 2>/dev/null)" ] || {
    printf '[ERROR] ENABLE_AMD=true but /opt/rocm in the package has no libamdhip64 anywhere (links unresolved?)\n' >&2
    return 1
  }
}

# targets/<arch>-linux/lib is on no default loader path; no-op on a CPU image.
publish_cuda_ld_path() {
  local lib
  : > /etc/ld.so.conf.d/000-cuda.conf
  for lib in /usr/local/cuda/targets/*/lib; do
    [ -d "${lib}" ] && printf '%s\n' "${lib}" >> /etc/ld.so.conf.d/000-cuda.conf
  done
  [ -s /etc/ld.so.conf.d/000-cuda.conf ] || rm -f /etc/ld.so.conf.d/000-cuda.conf
}

# /opt/rocm is on no default loader path; no-op without it.
publish_rocm_ld_path() {
  local lib
  : > /etc/ld.so.conf.d/000-rocm.conf
  # Dirs holding libamdhip64 or libmigraphx_c (extras-<major>/lib since 10.1), never core-asan-*: ASAN consumers preload it by hand.
  {
    find /opt/rocm -path '/opt/rocm/core-asan-*' -prune -o \( -name 'libamdhip64.so*' -o -name 'libmigraphx_c.so*' \) -printf '%h\n' 2>/dev/null || true
    printf '%s\n' /opt/rocm/lib /opt/rocm/lib64
  } | LC_ALL=C sort -u | while IFS= read -r lib; do
    # if, not `[ ] && printf`: a false last iteration would fail the while under set -e.
    if [ -n "${lib}" ] && [ -d "${lib}" ]; then printf '%s\n' "${lib}" >> /etc/ld.so.conf.d/000-rocm.conf; fi
  done
  [ -s /etc/ld.so.conf.d/000-rocm.conf ] || rm -f /etc/ld.so.conf.d/000-rocm.conf
}

# libtvm_compiler.so's libLLVM resolves only through this. See docs/artifact-copy-completeness.md § The llvm-target prefix fills what it needs, and nothing else
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
