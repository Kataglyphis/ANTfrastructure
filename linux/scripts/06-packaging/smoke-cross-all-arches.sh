#!/usr/bin/env bash
set -euo pipefail

# One probe per toolchain the image is supposed to carry: the host cc, the
# GCC_PREFIX gcc, each target's cross gcc/g++, the target-native clang, and the
# cc/c++/gcc/g++ symlink chain. Runs in the image and on the build host.
#   smoke-cross-all-arches.sh [amd64,arm64,riscv64]
# docs/cross-build-verification.md#cross-compiler-multi-arch-smoke

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

: "${GCC_PREFIX:=/opt/gcc-${GCC_VERSION:-16.2.0}}"
: "${GCC_VERSION:=16.2.0}"
: "${SMOKE_TARGET_CLANG:=/usr/local/llvm-target/bin/clang}"

smoke_load_platform

_smoke_probe_host_compilers() {
  local host_arch="$1"
  echo "--- Host compiler (cc) ---"
  if command -v cc >/dev/null 2>&1; then
    validate_compiler_for_target "$(command -v cc)" "${host_arch}" "cc (host)"
  else
    fail "Host cc not found"
  fi
  echo ""

  if [ -x "${GCC_PREFIX}/bin/gcc" ]; then
    echo "--- GCC host native (${GCC_PREFIX}/bin/gcc) ---"
    validate_compiler_for_target "${GCC_PREFIX}/bin/gcc" "${host_arch}" "gcc (host)"
    echo ""
  fi
  return 0
}

_smoke_probe_cross_compilers() {
  local target_arches="$1" host_arch="$2"
  local arch
  for arch in $(smoke_arch_words "${target_arches}"); do
    [ "${arch}" = "${host_arch}" ] && continue
    local triplet cross_gcc cross_gpp
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
  return 0
}

# Prints the first requested arch whose uname name prefixes the triple, empty
# when none does. docs/cross-build-verification.md#cross-compiler-multi-arch-smoke
_smoke_clang_match_arch() {
  local clang_dump="$1" target_arches="$2" expected arch
  for arch in $(smoke_arch_words "${target_arches}"); do
    expected="$(smoke_uname_name "${arch}" 2>/dev/null || true)"
    [ -n "${expected}" ] || continue
    if echo "${clang_dump}" | grep -q "^${expected}"; then
      printf '%s' "${arch}"
      return 0
    fi
  done
  return 0
}

# The binary has ONE default triple, so a sweep that stopped at the first arch
# reported nothing when the triple was wrong.
_smoke_probe_llvm_target_clang() {
  local target_arches="$1"
  [ -x "${SMOKE_TARGET_CLANG}" ] || return 0
  echo "--- Target-native Clang (${SMOKE_TARGET_CLANG}) ---"
  local clang_dump clang_matched
  clang_dump="$("${SMOKE_TARGET_CLANG}" -dumpmachine 2>/dev/null || true)"
  clang_matched="$(_smoke_clang_match_arch "${clang_dump}" "${target_arches}")"
  if [ -n "${clang_matched}" ]; then
    pass "clang (llvm-target): -dumpmachine=${clang_dump} (matches ${clang_matched})"
  else
    fail "clang (llvm-target): -dumpmachine=${clang_dump:-EMPTY} matches none of: ${target_arches}"
  fi
  echo ""
  return 0
}

_smoke_probe_symlink_chain() {
  echo "--- System symlink chain ---"
  local tool resolved
  for tool in cc c++ gcc g++; do
    resolved="$(readlink -f "$(command -v "${tool}" 2>/dev/null || true)" 2>/dev/null || true)"
    if [ -n "${resolved}" ]; then
      pass "${tool} -> ${resolved}"
    else
      fail "${tool} not found in PATH"
    fi
  done
  echo ""
  return 0
}

main() {
  local target_arches="${1:-amd64,arm64,riscv64}"
  local host_arch

  host_arch="$(canonical_target_arch 2>/dev/null || true)"
  if [ -z "${host_arch}" ]; then
    host_arch="$(smoke_host_arch)"
  fi

  echo "=== Cross-Compiler Multi-Arch Smoke Test ==="
  echo "Host arch: ${host_arch}"
  echo "GCC prefix: ${GCC_PREFIX}"
  echo "Target arches: ${target_arches}"
  echo ""

  _smoke_probe_host_compilers "${host_arch}"
  _smoke_probe_cross_compilers "${target_arches}" "${host_arch}"
  _smoke_probe_llvm_target_clang "${target_arches}"
  _smoke_probe_symlink_chain

  smoke_summary
}

main "$@"
