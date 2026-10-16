#!/usr/bin/env bash
# CPack's AppImage generator patches every library without a RUNPATH; a patched bundled loader segfaults, so glibc is left as built.
set -euo pipefail
for arg in "$@"; do
  case "$(basename -- "${arg}")" in
    ld-linux*.so* | libc.so.6 | libm.so.6 | libmvec.so.1 | libpthread.so.0 | libdl.so.2 | librt.so.1 | \
      libresolv.so.2 | libutil.so.1 | libanl.so.1 | libnss_*.so.2) exit 0 ;;
  esac
done
exec "${KATAGLYPHIS_PATCHELF:-patchelf}" "$@"
