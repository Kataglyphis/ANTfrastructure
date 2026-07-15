#!/usr/bin/env bash
set -euo pipefail
# verify-gcc.sh - Verification of GCC installation.
# Called from build-gcc.sh after GCC is installed and configured.

verify_gcc_installation() {
  local PREFIX="$1"
  local GCC_VERSION="$2"
  local SUDO="${3:-}"
  local failed=0

  echo
  echo "============================================"
  echo "=== Verification ==="
  echo "============================================"
  echo
  echo "Active GCC location:"
  which gcc || { echo "ERROR: gcc not found in PATH"; failed=1; }
  echo
  echo "Active GCC version:"
  gcc --version 2>/dev/null | head -n1 || { echo "ERROR: gcc --version failed"; failed=1; }
  echo
  echo "Active G++ location:"
  which g++ || echo "WARNING: g++ not found in PATH"
  echo
  echo "Active G++ version:"
  g++ --version 2>/dev/null | head -n1 || echo "WARNING: g++ --version failed"
  echo
  echo "Active CC location:"
  which cc || echo "WARNING: cc not found in PATH"
  echo
  echo "GCC alternative status:"
  ${SUDO} update-alternatives --display gcc 2>/dev/null | grep -E 'link currently points to|best version' || echo "WARNING: Could not query gcc alternative"
  echo
  echo "CC alternative status:"
  ${SUDO} update-alternatives --display cc 2>/dev/null | grep -E 'link currently points to|best version' || echo "WARNING: Could not query cc alternative"
  echo
  echo "Library search path (libstdc++ and libgcc):"
  ldconfig -p 2>/dev/null | grep -E "libstdc\+\+|libgcc_s" | head -n10 || echo "WARNING: Could not query library paths"
  echo
  echo "Environment files created:"
  ls -la /etc/profile.d/gcc-${GCC_VERSION}* 2>/dev/null || echo "No profile.d files found"
  echo
  echo "LD config file:"
  ls -la /etc/ld.so.conf.d/gcc-${GCC_VERSION}.conf 2>/dev/null || echo "No ld.so.conf.d file found"
  echo
  echo "/etc/environment content (GCC-related lines):"
  grep -E 'PATH|PKG_CONFIG_PATH|LD_LIBRARY_PATH' /etc/environment 2>/dev/null || echo "Could not read /etc/environment"
  echo
  echo "============================================"
  echo "Installation complete!"
  echo "============================================"
  echo
  echo "IMPORTANT: To activate the new GCC in your current shell, run:"
  echo "  source /etc/profile.d/gcc-${GCC_VERSION}-path.sh"
  echo "  source /etc/profile.d/gcc-${GCC_VERSION}-pkgconfig.sh"
  echo
  echo "Or for Docker/non-interactive shells, the paths are already in /etc/environment"
  echo "and will be available in new shell sessions or after sourcing /etc/environment."
  echo
  return "${failed}"
}

