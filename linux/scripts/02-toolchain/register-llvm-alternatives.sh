#!/usr/bin/env bash
set -euo pipefail

# Points clang, clang++, llvm-ar and llvm-ranlib at the LLVM_RELEASE major.

llvm_major="${LLVM_RELEASE%%.*}"

alt_install() {
  local name="$1"
  local priority="${2:-120}"
  local candidate

  # Source-built LLVM first: the apt bootstrap lags point releases, and the smoke asserts clang == LLVM_RELEASE.
  for candidate in \
    "/usr/local/llvm-${llvm_major}/bin/${name}" \
    "/usr/lib/llvm-${llvm_major}/bin/${name}" \
    "/usr/bin/${name}-${llvm_major}"; do
    if [ -x "${candidate}" ]; then
      update-alternatives --install "/usr/bin/${name}" "${name}" "${candidate}" "${priority}"
      update-alternatives --set "${name}" "${candidate}"
      return 0
    fi
  done
  echo "WARNING: could not find ${name} for LLVM ${llvm_major}" >&2
}

alt_install clang
alt_install clang++
alt_install llvm-ar
alt_install llvm-ranlib