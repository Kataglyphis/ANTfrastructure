#!/usr/bin/env bash
# Per-arch string mappings not already in platform.sh or cross-env.sh; an unknown arch returns 1.

[ -n "${_ARCH_MAPPING_SH_LOADED:-}" ] && return 0
_ARCH_MAPPING_SH_LOADED=1

_ARCH_MAPPING_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090,SC1091
[ -f "${_ARCH_MAPPING_SH_DIR}/platform.sh" ] && source "${_ARCH_MAPPING_SH_DIR}/platform.sh"

# The full readelf "Machine:" name, unlike arch_elf_machine_grep_for's short grep substring.
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
