#!/usr/bin/env bash
# Select only the source-owned native tree; existence does not prove versions, linking or inference.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "Usage: register-llvm-alternatives.sh ABSOLUTE_NATIVE_PREFIX" >&2; exit 2; }
prefix="$1"
case "${prefix}" in
  /*) ;;
  *) echo "Native LLVM prefix must be absolute" >&2; exit 2 ;;
esac

tools=(clang clang++ llvm-ar llvm-ranlib)
# Refuse incomplete installs before changing any alternative.
for name in "${tools[@]}"; do
  [ -x "${prefix}/bin/${name}" ] || { echo "Missing source-built LLVM tool: ${prefix}/bin/${name}" >&2; exit 1; }
done
for name in "${tools[@]}"; do
  update-alternatives --install "/usr/bin/${name}" "${name}" "${prefix}/bin/${name}" 120
  update-alternatives --set "${name}" "${prefix}/bin/${name}"
done
