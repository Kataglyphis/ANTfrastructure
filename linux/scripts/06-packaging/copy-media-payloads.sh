#!/usr/bin/env bash
set -euo pipefail

# Usage: [SRCPREFIX=<artifact mount>] copy-media-payloads.sh [dest-prefix]

SRCPREFIX="${SRCPREFIX:-}"

# warn is undefined when this runs standalone.
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
  copy_deepstream_payload

  unset COPY_TARGET_DIR
}

# Every CUDA-built library needs the toolkit, cuDNN and NCCL to load; ENABLE_NVIDIA=true without them is fatal.
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
  # Relink relatively: through the bind mount /etc/alternatives resolves in the build container.
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
