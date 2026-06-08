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

_dest() {
  local rel="${1:-}"
  local target_dir="${COPY_TARGET_DIR:-}"
  printf '%s' "${target_dir}${rel}"
}

copy_path() {
  local src="${SRCPREFIX}$1"
  local dst
  dst="$(_dest "${2:-$1}")"
  [ -e "${src}" ] || return 0
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
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
    /usr/local/llvm-target \
    /usr/local/llvm-22; do
    copy_path "${path}"
  done

  for pattern in \
    '/usr/local/lib/libLiteRt.so*' \
    '/usr/local/lib/libtensorflow-lite.so*' \
    '/usr/local/lib/libtensorflowlite_c.so*' \
    '/usr/local/lib/libvvdec.so*'; do
    copy_glob "${pattern}"
  done

  unset COPY_TARGET_DIR
}

main() {
  copy_media_payloads "${1:-}"
}

main "$@"
