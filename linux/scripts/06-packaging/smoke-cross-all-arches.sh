#!/usr/bin/env bash
set -euo pipefail

# smoke-cross-all-arches.sh
# Multi-architecture cross-compiler smoke test for all 3 target arches.
# Validates that each cross-compiler produces correct ELF machine type output
# for its target architecture.
#
# Usage:
#   smoke-cross-all-arches.sh              # test all arches
#   smoke-cross-all-arches.sh amd64,arm64  # test specific arches
#
# This script optionally sources platform.sh for ELF helpers.  It is safe to
# run both inside a Docker image and standalone on the build host.

# Source shared smoke utilities
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

: "${GCC_PREFIX:=/opt/gcc-${GCC_VERSION:-16.1.0}}"
: "${GCC_VERSION:=16.1.0}"

# Load platform helpers (from 01-core) if available
if [ -f "${_SCRIPT_DIR}/../01-core/platform.sh" ]; then
  source "${_SCRIPT_DIR}/../01-core/platform.sh" 2>/dev/null || true
fi

main() {
  local target_arches="${1:-amd64,arm64,riscv64}"
  local arch
  local host_arch

  host_arch="$(canonical_target_arch 2>/dev/null || echo "${host_arch:-}")"
  if [ -z "${host_arch}" ]; then
    host_arch="$(smoke_host_arch)"
  fi

  echo "=== Cross-Compiler Multi-Arch Smoke Test ==="
  echo "Host arch: ${host_arch}"
  echo "GCC prefix: ${GCC_PREFIX}"
  echo "Target arches: ${target_arches}"
  echo ""

  # 1. Test host compiler
  echo "--- Host compiler (cc) ---"
  if command -v cc >/dev/null 2>&1; then
    validate_compiler_for_target "$(command -v cc)" "${host_arch}" "cc (host)"
  else
    fail "Host cc not found"
  fi
  echo ""

  # 2. Test main GCC for host
  if [ -x "${GCC_PREFIX}/bin/gcc" ]; then
    echo "--- GCC host native (${GCC_PREFIX}/bin/gcc) ---"
    validate_compiler_for_target "${GCC_PREFIX}/bin/gcc" "${host_arch}" "gcc (host)"
    echo ""
  fi

  # 3. Test cross-compilers for each target arch
  for arch in $(smoke_arch_words "${target_arches}"); do
    [ "${arch}" = "${host_arch}" ] && continue
    local triplet cross_gcc
    triplet="$(smoke_deb_triplet "${arch}" 2>/dev/null || true)"
    [ -n "${triplet}" ] || { fail "Cannot determine triplet for ${arch}"; continue; }

    cross_gcc="${GCC_PREFIX}/bin/${triplet}-gcc"
    if [ -x "${cross_gcc}" ]; then
      echo "--- Cross compiler: ${arch} (${cross_gcc}) ---"
      validate_compiler_for_target "${cross_gcc}" "${arch}" "${triplet}-gcc (cross-${arch})" cross
    else
      fail "Cross GCC for ${arch} not found at ${cross_gcc}"
    fi

    cross_gpp="${GCC_PREFIX}/bin/${triplet}-g++"
    if [ -x "${cross_gpp}" ]; then
      check_dumpmachine "${cross_gpp}" \
        "$(smoke_uname_name "${arch}" 2>/dev/null || true)" \
        "${triplet}-g++ (cross-${arch})"
    fi
    echo ""
  done

  # 4. Test target-native Clang if available
  if [ -x /usr/local/llvm-target/bin/clang ]; then
    echo "--- Target-native Clang (/usr/local/llvm-target/bin/clang) ---"
    for arch in $(smoke_arch_words "${target_arches}"); do
      local clang_arch
      clang_arch="$(/usr/local/llvm-target/bin/clang -dumpmachine 2>/dev/null || true)"
      local expected
      expected="$(smoke_uname_name "${arch}" 2>/dev/null || true)"
      if echo "${clang_arch}" | grep -q "^${expected}"; then
        pass "clang (llvm-target): -dumpmachine=${clang_arch} (expected ${arch})"
      fi
      break  # single target
    done
    echo ""
  fi

  # 5. Check system symlink chain
  echo "--- System symlink chain ---"
  for tool in cc c++ gcc g++; do
    local resolved
    resolved="$(readlink -f "$(command -v "${tool}" 2>/dev/null || true)" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
      pass "${tool} -> ${resolved}"
    else
      fail "${tool} not found in PATH"
    fi
  done
  echo ""

  smoke_summary
}

main "$@"
