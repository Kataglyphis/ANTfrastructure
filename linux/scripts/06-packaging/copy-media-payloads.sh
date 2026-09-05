#!/usr/bin/env bash
set -euo pipefail

# copy-media-payloads.sh
# Shared helper to copy lightweight media library payloads (LiteRT, VVdec,
# ONNX Runtime GenAI/GPU) from the artifact image into the package image.
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
    '/usr/local/lib/libtvm_compiler.so*'; do
    copy_glob "${pattern}"
  done

  unset COPY_TARGET_DIR
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
  publish_llvm_target_ld_path
}

main "$@"
