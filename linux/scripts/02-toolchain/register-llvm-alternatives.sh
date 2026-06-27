#!/usr/bin/env bash
set -euo pipefail

# register-llvm-alternatives.sh
#
# Registers clang, clang++, llvm-ar, and llvm-ranlib as the system default
# alternatives, preferring the requested LLVM major version from /usr/lib/llvm-N/bin/
# or /usr/bin/*-N patterns.
#
# Environment:
#   LLVM_RELEASE   e.g. "22.1.8"

llvm_major="${LLVM_RELEASE%%.*}"

alt_install() {
  local name="$1"
  local priority="${2:-120}"
  local candidate

  for candidate in \
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