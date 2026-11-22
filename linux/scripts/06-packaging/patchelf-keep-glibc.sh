#!/usr/bin/env bash
# CPack must retain glibc and any explicitly byte-matched runtime or helper payloads.
set -euo pipefail
keep_ort=0
keep_names=()
while :; do
  case "${1:-}" in
    --keep-ort) keep_ort=1; shift ;;
    --keep-name)
      [[ $# -ge 2 && "$2" =~ ^[a-zA-Z0-9_.+\ -]+$ && "$2" != . && "$2" != .. ]] || { echo 'Invalid preserved executable basename' >&2; exit 2; }
      keep_names+=("$2"); shift 2 ;;
    *) break ;;
  esac
done
target=""
[[ $# -eq 0 ]] || target="${!#}"
for name in "${keep_names[@]}"; do
  [[ "${target##*/}" != "${name}" ]] || exit 0
done
for arg in "$@"; do
  case "$(basename -- "${arg}")" in
    ld-linux*.so* | libc.so.6 | libm.so.6 | libmvec.so.1 | libpthread.so.0 | libdl.so.2 | librt.so.1 | \
      libresolv.so.2 | libutil.so.1 | libanl.so.1 | libnss_*.so.2) exit 0 ;;
    libonnxruntime*.so*|libmigraphx-ep.so) if [[ "${keep_ort}" == 1 ]]; then exit 0; fi ;;
  esac
done
exec "${KATAGLYPHIS_PATCHELF:-patchelf}" "$@"
