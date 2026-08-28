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

# DF3 (2026-08-18, moved verbatim from an inline Dockerfile.package RUN):
# Make /usr/local/llvm-target SELF-CONTAINED (2026-08-11): the amd64 copy
# (apt.llvm.org tree) ships only dev symlinks in lib/ — its runtime sonames
# (libLLVM.so.22.1, libclang-cpp.so.22.1) live in the MULTIARCH dir and were
# never copied, so the shipped clang silently bound to whatever ambient
# libLLVM the image carried. Since the dev-surface packages install Ubuntu's
# libs, amd64's effective clang became a mixed-version franken build —
# exposed when the clang smoke started EXECUTING the tool. Copy the
# artifact's matching runtime libs next to the driver and give
# llvm-target/lib loader priority. No-op on arm64/riscv64 (source-built with
# $ORIGIN RPATH and their own complete lib/).
# UPDATE 2026-08-12 (BS3b): the ROOT fix lives in Dockerfile.sdk (amd64
# branch copies the multiarch sonames + NEEDED-walk gate), so this block
# should find every soname already present. KEEP: belt-and-braces for
# pre-fix sdk artifacts + the dangling-symlink repair. Removal candidate
# once a full rebuild shows it copying nothing on all three arches.
repair_llvm_target_sonames() {
  local _lib _soname
  for _lib in "${SRCPREFIX}"/usr/lib/*-linux-gnu/libLLVM*.so.2*               "${SRCPREFIX}"/usr/lib/*-linux-gnu/libclang-cpp*.so.2*               "${SRCPREFIX}"/usr/lib/*-linux-gnu/libclang*.so.2*; do
    [ -e "${_lib}" ] || continue
    _soname="$(basename "${_lib}")"
    # -e is FALSE for a dangling symlink (the apt.llvm.org tree ships exactly
    # such a stale .so.22.1 link into the void) — rm it first or cp refuses
    # "not writing through dangling symlink". A REAL lib (arm64/riscv64
    # source builds) still short-circuits the copy.
    if [ ! -e "/usr/local/llvm-target/lib/${_soname}" ]; then
      rm -f "/usr/local/llvm-target/lib/${_soname}"
      cp -a "${_lib}" "/usr/local/llvm-target/lib/${_soname}"
    fi
  done
  printf '/usr/local/llvm-target/lib\n' > /etc/ld.so.conf.d/000-llvm-target.conf
  ldconfig
}

main() {
  copy_media_payloads "${1:-}"
  repair_llvm_target_sonames
}

main "$@"
