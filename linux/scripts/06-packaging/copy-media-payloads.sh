#!/usr/bin/env bash
set -euo pipefail

# copy-media-payloads.sh
# Shared helper to copy lightweight media library payloads (LiteRT, VVdec,
# ONNX Runtime GenAI/GPU) from the artifact image into the package image.
# Deduplicates the copy_path/copy_glob pattern previously defined inline
# twice in Dockerfile.package.
#
# Usage:
#   copy-media-payloads.sh              Copy onto the local filesystem.
#   copy-media-payloads.sh /payload     Copy into a staging prefix.
#   SRCPREFIX=/runtime_artifact \
#     copy-media-payloads.sh            Copy from a bind-mounted source prefix.

SRCPREFIX="${SRCPREFIX:-}"

copy_path() {
  local src="${SRCPREFIX}$1"
  local dst="${2:-$1}"
  [ -e "${src}" ] || return 0
  mkdir -p "$(dirname "${dst}")"
  cp -a "${src}" "${dst}"
}

copy_glob() {
  local pattern="${SRCPREFIX}$1"
  local item rel
  shopt -s nullglob
  for item in ${pattern}; do
    rel="${item#${SRCPREFIX}}"
    mkdir -p "$(dirname "${rel}")"
    cp -a "${item}" "${rel}"
  done
  shopt -u nullglob
}

copy_path_to() {
  local src="${SRCPREFIX}$1"
  local dst="$2"
  local target_dir="$3"
  [ -e "${src}" ] || return 0
  mkdir -p "${target_dir}$(dirname "${dst}")"
  cp -a "${src}" "${target_dir}${dst}"
}

copy_glob_to() {
  local pattern="${SRCPREFIX}$1"
  local target_dir="$2"
  local item rel
  shopt -s nullglob
  for item in ${pattern}; do
    rel="${item#${SRCPREFIX}}"
    mkdir -p "${target_dir}$(dirname "${rel}")"
    cp -a "${item}" "${target_dir}${rel}"
  done
  shopt -u nullglob
}

copy_media_payloads() {
  local target_dir="${1:-}"

  local _copy_path _copy_glob
  if [ -n "${target_dir}" ]; then
    _copy_path() { copy_path_to "$1" "$1" "${target_dir}"; }
    _copy_glob() { copy_glob_to "$1" "${target_dir}"; }
  else
    _copy_path() { copy_path "$@"; }
    _copy_glob() { copy_glob "$@"; }
  fi

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
    _copy_path "${path}"
  done

  for pattern in \
    '/usr/local/lib/libLiteRt.so*' \
    '/usr/local/lib/libtensorflow-lite.so*' \
    '/usr/local/lib/libtensorflowlite_c.so*' \
    '/usr/local/lib/libvvdec.so*'; do
    _copy_glob "${pattern}"
  done
}

main() {
  copy_media_payloads "${1:-}"
}

main "$@"
