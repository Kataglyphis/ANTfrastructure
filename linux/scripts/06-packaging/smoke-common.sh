#!/usr/bin/env bash
set -euo pipefail
# smoke-common.sh
# Shared smoke test utilities: pass/fail with FAILURES tracking, version checks,
# and ELF verification helpers.  Source this in all *-smoke.sh scripts.
#
# Usage:
#   source "$(dirname "$0")/smoke-common.sh"
#   source_module platform.sh   # for ELF/arch helpers if not already loaded

if [ -n "${_SMOKE_COMMON_LOADED:-}" ]; then
  return 0
fi
_SMOKE_COMMON_LOADED=1

FAILURES=0

# Fallback for cross_build_is_active when cross-env.sh is not loaded.
# The real definition in cross-env.sh checks both BUILD_MODE and arch mismatch.
# This fallback approximates it by checking BUILD_MODE and TARGET_ARCH != build arch.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  cross_build_is_active() {
    [ "${BUILD_MODE:-native}" = "cross" ] && \
    [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "${BUILDARCH:-$(uname -m)}" ]
  }
fi

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# Check that a command's output contains an expected string.
# Usage: check_version "gcc --version" "16.1.0" "host gcc"
check_version() {
  local cmd="$1" expected="$2" label="$3"
  local ver
  ver="$(${cmd} 2>/dev/null | head -1 || true)"
  if echo "${ver}" | grep -q "${expected}"; then
    pass "${label}: ${ver}"
  else
    fail "${label}: ${ver:-MISSING} (expected ${expected})"
  fi
}

# Check that a compiler's -dumpmachine starts with the expected prefix.
# Usage: check_dumpmachine "/opt/gcc-16.1.0/bin/gcc" "x86_64" "host gcc"
check_dumpmachine() {
  local cc="$1" expected="$2" label="$3"
  local dump
  [ -x "${cc}" ] || { fail "${label}: ${cc} not found"; return 1; }
  dump="$("${cc}" -dumpmachine 2>/dev/null || true)"
  if echo "${dump}" | grep -q "^${expected}"; then
    pass "${label}: -dumpmachine=${dump}"
  else
    fail "${label}: -dumpmachine=${dump} != ${expected}"
  fi
}

# Check that a binary's ELF Machine: field contains the expected substring.
# Usage: check_elf_machine "/opt/gcc-16.1.0/bin/gcc" "X86-64" "host gcc"
check_elf_machine() {
  local bin="$1" expected="$2" label="$3"
  local machine
  [ -f "${bin}" ] || { fail "${label}: ${bin} not found"; return 1; }
  if command -v readelf >/dev/null 2>&1; then
    machine="$(readelf -h "${bin}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
    case "${machine}" in
      *"${expected}"*) pass "${label}: ELF machine=${machine}" ;;
      *) fail "${label}: ELF machine=${machine} != ${expected}" ;;
    esac
  fi
}

# Full cross-compiler validation for a target architecture.
# Runs: -dumpmachine, ELF machine, cc1 compile-to-object, link smoke.
# Usage: validate_compiler_for_target "/path/to/cross-gcc" "arm64" "cross-gcc (arm64)"
validate_compiler_for_target() {
  local cc_path="$1"
  local target_arch="$2"
  local label="${3:-${cc_path}}"
  local expected_pattern expected_machine cc_dump cc_machine tmpdir cc_obj

  if command -v arch_uname_name_for >/dev/null 2>&1; then
    expected_pattern="$(arch_uname_name_for "${target_arch}")"
  else
    case "${target_arch}" in
      amd64)   expected_pattern="x86_64" ;;
      arm64)   expected_pattern="aarch64" ;;
      riscv64) expected_pattern="riscv64" ;;
      *)       fail "Unknown arch: ${target_arch}"; return 1 ;;
    esac
  fi

  if command -v arch_elf_machine_grep_for >/dev/null 2>&1; then
    expected_machine="$(arch_elf_machine_grep_for "${target_arch}" 2>/dev/null || true)"
  else
    case "${target_arch}" in
      amd64)   expected_machine="X86-64" ;;
      arm64)   expected_machine="AArch64" ;;
      riscv64) expected_machine="RISC-V" ;;
      *)       expected_machine="" ;;
    esac
  fi

  [ -n "${expected_pattern}" ] || { fail "Unknown arch: ${target_arch}"; return 1; }

  # dumpmachine check
  cc_dump="$("${cc_path}" -dumpmachine 2>/dev/null || true)"
  if [ -z "${cc_dump}" ]; then
    fail "${label}: -dumpmachine returned empty"
    return 1
  fi
  if echo "${cc_dump}" | grep -q "^${expected_pattern}"; then
    pass "${label}: -dumpmachine=${cc_dump} (expected ${target_arch})"
  else
    fail "${label}: -dumpmachine=${cc_dump} != expected ${expected_pattern}"
  fi

  # ELF machine check
  if command -v readelf >/dev/null 2>&1; then
    cc_machine="$(readelf -h "${cc_path}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
    if [ -n "${cc_machine}" ]; then
      case "${cc_machine}" in
        *"${expected_machine}"*) pass "${label}: ELF machine=${cc_machine}" ;;
        *) fail "${label}: ELF machine=${cc_machine} != expected ${expected_machine}" ;;
      esac
    else
      fail "${label}: cannot read ELF machine type"
    fi
  fi

  # cc1 compile-to-object smoke
  tmpdir="$(mktemp -d)"
  cc_obj="${tmpdir}/smoke.o"
  if printf 'int answer(void){return 42;}\n' | "${cc_path}" -x c - -c -o "${cc_obj}" 2>/dev/null; then
    pass "${label}: cc1 compile-to-object smoke OK"
    if command -v readelf >/dev/null 2>&1 && [ -f "${cc_obj}" ]; then
      local obj_machine
      obj_machine="$(readelf -h "${cc_obj}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
      case "${obj_machine}" in
        *"${expected_machine}"*) pass "${label}: object ELF machine=${obj_machine}" ;;
        *) fail "${label}: object ELF machine=${obj_machine} != expected ${expected_machine}" ;;
      esac
    fi
  else
    fail "${label}: cc1 compile-to-object smoke FAILED"
  fi
  rm -rf "${tmpdir}"

  # link smoke
  tmpdir="$(mktemp -d)"
  local cc_exe="${tmpdir}/smoke"
  if printf 'int main(void){return 0;}\n' | "${cc_path}" -x c - -o "${cc_exe}" 2>/dev/null; then
    pass "${label}: link smoke OK"
  else
    fail "${label}: link smoke FAILED (missing crt/startup files?)"
  fi
  rm -rf "${tmpdir}"
}
