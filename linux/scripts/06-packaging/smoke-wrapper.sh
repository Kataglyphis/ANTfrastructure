#!/usr/bin/env bash
set -euo pipefail

# smoke-wrapper.sh
# Hard-fail smoke verification for the runtime wrapper image.
# Delegates all compiler and payload validation to validate-compilers.sh.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${_SCRIPT_DIR}/smoke-common.sh"

VALIDATE_COMPILERS="/opt/scripts/packaging/validate-compilers.sh"

main() {
  local gcc_ver="${GCC_VERSION:-16.1.0}"
  local llvm_ver="${LLVM_RELEASE:-22.1.8}"
  local target_arch

  target_arch="${TARGET_ARCH:-${TARGETARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}}"
  # Prefer the canonical platform.sh arch_normalize when the image ships it;
  # smoke_host_arch falls back to the inline case otherwise.
  [ -f /opt/scripts/core/platform.sh ] && source /opt/scripts/core/platform.sh
  target_arch="$(smoke_host_arch "${target_arch}")"

  echo "=== smoke: target_arch=${target_arch} ==="

  if [ ! -x "${VALIDATE_COMPILERS}" ]; then
    echo "SMOKE FAIL: validate-compilers.sh not found" >&2
    exit 1
  fi

  echo "=== smoke: running shared compiler validation ==="
  GCC_VERSION="${gcc_ver}" \
  LLVM_RELEASE="${llvm_ver}" \
  TARGET_ARCH="${target_arch}" \
  bash "${VALIDATE_COMPILERS}" smoke || {
    echo "SMOKE FAIL: shared compiler validation failed" >&2
    exit 1
  }

  echo "SMOKE PASSED: all checks OK for ${target_arch}"
}

main "$@"