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
# Both sides are normalized to OCI names via smoke_host_arch (defined below;
# resolved at call time) — TARGET_ARCH is usually an OCI name (amd64/arm64)
# while uname -m yields machine names (x86_64/aarch64), so a raw comparison
# never matched and native wrapper images skipped their functional checks.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  cross_build_is_active() {
    [ "${BUILD_MODE:-native}" = "cross" ] || return 1
    local _target="${TARGET_ARCH:-${TARGETARCH:-}}"
    [ -n "${_target}" ] && _target="$(smoke_host_arch "${_target}")"
    [ "${_target}" != "$(smoke_host_arch "${BUILDARCH:-$(uname -m)}")" ]
  }
fi

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

# Print the standard result banner and exit non-zero on any failure.
# Replaces the copy-pasted "=== Results: N failure(s) ===" + exit tail (and the
# duplicate print_results() defs in smoke-android.sh / smoke-vulkan.sh).
smoke_summary() {
  echo "=== Results: ${FAILURES} failure(s) ==="
  [ "${FAILURES}" -eq 0 ] || exit 1
}

# ── arch-map helpers ────────────────────────────────────────────────────────
# Always-available thin wrappers over the canonical 01-core/platform.sh arch
# functions.  Each prefers the platform.sh function when it has been sourced,
# and otherwise applies the inline case ONCE.  These replace the ~10 copies of
# `command -v arch_* || case "${arch}" in …` scattered across the smoke scripts.
# All cover the three supported target arches (amd64/arm64/riscv64).

# uname -m style machine name for a target arch (amd64 -> x86_64, …).
smoke_uname_name() {
  if command -v arch_uname_name_for >/dev/null 2>&1; then
    arch_uname_name_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64' ;;
      arm64)   printf '%s' 'aarch64' ;;
      riscv64) printf '%s' 'riscv64' ;;
      *)       return 1 ;;
    esac
  fi
}

# OCI/Docker arch name for a machine name (default: $(uname -m)).
# x86_64 -> amd64, aarch64 -> arm64, riscv64 -> riscv64; unknown passes through.
smoke_host_arch() {
  local raw="${1:-$(uname -m)}"
  if command -v arch_normalize >/dev/null 2>&1; then
    arch_normalize "${raw}"
  else
    case "${raw}" in
      x86_64)  printf '%s' 'amd64' ;;
      aarch64) printf '%s' 'arm64' ;;
      riscv64) printf '%s' 'riscv64' ;;
      *)       printf '%s' "${raw}" ;;
    esac
  fi
}

# Debian multiarch triplet for a target arch (amd64 -> x86_64-linux-gnu, …).
smoke_deb_triplet() {
  if command -v arch_deb_multiarch_triplet_for >/dev/null 2>&1; then
    arch_deb_multiarch_triplet_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64-linux-gnu' ;;
      arm64)   printf '%s' 'aarch64-linux-gnu' ;;
      riscv64) printf '%s' 'riscv64-linux-gnu' ;;
      *)       return 1 ;;
    esac
  fi
}

# readelf -h "Machine:" substring for a target arch (amd64 -> X86-64, …).
smoke_elf_machine_grep() {
  if command -v arch_elf_machine_grep_for >/dev/null 2>&1; then
    arch_elf_machine_grep_for "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'X86-64' ;;
      arm64)   printf '%s' 'AArch64' ;;
      riscv64) printf '%s' 'RISC-V' ;;
      *)       return 1 ;;
    esac
  fi
}

# Rust target triple for a target arch (amd64 -> x86_64-unknown-linux-gnu, …).
smoke_rust_target() {
  if command -v arch_rust_target_triple_for >/dev/null 2>&1; then
    arch_rust_target_triple_for "$1"
  elif command -v rust_target_triple >/dev/null 2>&1; then
    rust_target_triple "$1"
  else
    case "$1" in
      amd64)   printf '%s' 'x86_64-unknown-linux-gnu' ;;
      arm64)   printf '%s' 'aarch64-unknown-linux-gnu' ;;
      riscv64) printf '%s' 'riscv64gc-unknown-linux-gnu' ;;
      *)       return 1 ;;
    esac
  fi
}

# Load the canonical 01-core/platform.sh arch helpers when available, from the
# baked-image layout (/opt/scripts/core) or the repo layout — whichever exists
# first. Best-effort: the smoke_* wrappers above fall back to their inline
# maps when platform.sh is absent. Replaces the hand-rolled copies that lived
# in smoke-cross-all-arches.sh, smoke-toolchain.sh, and smoke-wrapper.sh.
smoke_load_platform() {
  local _dir _p
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for _p in /opt/scripts/core/platform.sh "${_dir}/../01-core/platform.sh"; do
    if [ -f "${_p}" ]; then
      # shellcheck disable=SC1090
      source "${_p}" 2>/dev/null || true
      return 0
    fi
  done
  return 0
}

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

# Full compiler validation for a target architecture.
# Runs: -dumpmachine, ELF machine, cc1 compile-to-object, link smoke.
# Usage: validate_compiler_for_target <cc_path> <target_arch> [label] [mode]
#   mode=native (default) — the compiler BINARY is expected to be target-arch
#     (target-native compiler, e.g. the packaged cc); its ELF machine is checked.
#   mode=cross            — the compiler is a cross compiler whose BINARY is
#     host-arch (it merely emits target code), so the binary-ELF check is skipped;
#     the produced object/exe ELF (checked below) is what must be target-arch.
validate_compiler_for_target() {
  local cc_path="$1"
  local target_arch="$2"
  local label="${3:-${cc_path}}"
  local mode="${4:-native}"
  local expected_pattern expected_machine cc_dump cc_machine tmpdir cc_obj

  # `|| true` so the guard below is REACHABLE: smoke_uname_name returns 1 on an
  # unknown arch, and under set -e the bare substitution killed the script
  # before the intended "Unknown arch" fail could fire.
  expected_pattern="$(smoke_uname_name "${target_arch}" 2>/dev/null || true)"
  expected_machine="$(smoke_elf_machine_grep "${target_arch}" 2>/dev/null || true)"

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

  # ELF machine check of the compiler BINARY — native mode only. A cross
  # compiler's binary is host-arch (it emits target code), so this check does
  # not apply; the object/exe ELF checks below verify the emitted code instead.
  if [ "${mode}" != "cross" ] && command -v readelf >/dev/null 2>&1; then
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

# Split a comma/space-separated arch list into words. Self-contained on purpose:
# the smoke scripts source only smoke-common.sh + platform.sh and run under a
# non-login `bash -c` in Dockerfile.package, so they must NOT depend on
# 01-core/build-helpers.sh being sourced. They previously called that file's
# arch_list_to_words unqualified — undefined here, so the cross-compiler loops
# silently produced an empty list ("0 failures" with nothing actually tested).
smoke_arch_words() {
  printf '%s' "${1:-}" | tr ',' ' '
}
