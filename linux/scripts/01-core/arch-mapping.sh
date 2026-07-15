#!/usr/bin/env bash
# arch-mapping.sh - single source of truth for per-architecture string
# mappings that were previously hardcoded inline in 02-toolchain/ and
# 06-packaging/ scripts.
#
# This file complements (and must NOT duplicate) the existing helpers:
#   platform.sh:  arch_normalize, arch_uname_name_for,
#                 arch_deb_multiarch_triplet_for, arch_elf_machine_grep_for, ...
#   cross-env.sh: cross_target_triplet, cross_target_rust_triple, ...
#
# Conventions (same as platform.sh): functions take the architecture as $1,
# normalize it, map via case + printf, and return 1 with a message on stderr
# for an unknown architecture.

[ -n "${_ARCH_MAPPING_SH_LOADED:-}" ] && return 0
_ARCH_MAPPING_SH_LOADED=1

_ARCH_MAPPING_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# arch_normalize lives in platform.sh (no-op if it is already loaded).
# shellcheck disable=SC1090,SC1091
[ -f "${_ARCH_MAPPING_SH_DIR}/platform.sh" ] && source "${_ARCH_MAPPING_SH_DIR}/platform.sh"

# Full ELF machine name exactly as printed by `readelf -h` on the "Machine:"
# line. Note: arch_elf_machine_grep_for() (platform.sh) returns a *short grep
# substring* ("X86-64"); this returns the *full* canonical name used by the
# strict expected-machine checks in validate-compilers.sh.
arch_to_elf_machine() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "Advanced Micro Devices X86-64" ;;
    arm64) printf '%s' "AArch64" ;;
    riscv64) printf '%s' "RISC-V" ;;
    *) printf 'arch_to_elf_machine: unknown arch: %s\n' "$1" >&2; return 1 ;;
  esac
}

# LLVM backend name for an architecture (LLVM_TARGETS_TO_BUILD value).
arch_to_llvm_target() {
  case "$(arch_normalize "$1")" in
    amd64) printf '%s' "X86" ;;
    arm64) printf '%s' "AArch64" ;;
    riscv64) printf '%s' "RISCV" ;;
    *) printf 'arch_to_llvm_target: unknown arch: %s\n' "$1" >&2; return 1 ;;
  esac
}
