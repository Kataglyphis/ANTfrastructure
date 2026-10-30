#!/usr/bin/env bash
# CPack must not patch glibc; an opt-in also preserves wheel-matched ONNX Runtime files.
set -euo pipefail
keep_ort=0
if [[ "${1:-}" == --keep-ort ]]; then keep_ort=1; shift; fi
for arg in "$@"; do
  case "$(basename -- "${arg}")" in
    ld-linux*.so* | libc.so.6 | libm.so.6 | libmvec.so.1 | libpthread.so.0 | libdl.so.2 | librt.so.1 | \
      libresolv.so.2 | libutil.so.1 | libanl.so.1 | libnss_*.so.2) exit 0 ;;
    libonnxruntime*.so*) if [[ "${keep_ort}" == 1 ]]; then exit 0; fi ;;
  esac
done
exec "${KATAGLYPHIS_PATCHELF:-patchelf}" "$@"
