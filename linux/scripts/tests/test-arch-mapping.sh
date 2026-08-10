#!/usr/bin/env bash
# Tests for 01-core/arch-mapping.sh — per-architecture string mappings used by
# the strict compiler/ELF validation scripts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/arch-mapping.sh"

t_case "arch_to_elf_machine maps all supported arches"
t_assert_eq "Advanced Micro Devices X86-64" "$(arch_to_elf_machine amd64)"
t_assert_eq "AArch64"                        "$(arch_to_elf_machine arm64)"
t_assert_eq "RISC-V"                         "$(arch_to_elf_machine riscv64)"

t_case "uname-style spellings normalize"
t_assert_eq "AArch64" "$(arch_to_elf_machine aarch64)"
t_assert_eq "Advanced Micro Devices X86-64" "$(arch_to_elf_machine x86_64)"

t_case "unknown arch is a hard error"
t_assert_fails arch_to_elf_machine mips64

t_case "arch_to_llvm_target maps backends"
t_assert_eq "X86"     "$(arch_to_llvm_target amd64)"
t_assert_eq "AArch64" "$(arch_to_llvm_target arm64)"
t_assert_eq "RISCV"   "$(arch_to_llvm_target riscv64)" "LLVM backend dir is RISCV — a 'consistency' rename to RISCV64 breaks the compiler stage"

# arch_list_csv_normalize MUST emit COMMA-separated output even when the
# CALLER runs under a strict IFS (e.g. build_python.sh sets IFS=$'\n\t'). The
# pre-2026-08-09 implementation joined "${normalized_arches[*]}" with the
# caller's IFS first char and only tr'ed spaces, so under IFS=$'\n\t' the list
# came back newline-separated: build_python.sh's IFS=',' split then saw ONE
# bogus multi-line arch, staging nothing for arm64/riscv64 (regression found
# by the toolchain smoke's absent-cross-Python gate).
t_case "arch_list_csv_normalize is IFS-independent (strict caller IFS must still yield CSV)"
t_assert_eq "amd64,arm64,riscv64" \
  "$(IFS=$'\n\t'; arch_list_csv_normalize 'amd64,arm64,riscv64')"
t_assert_eq "amd64,arm64,riscv64,386" \
  "$(IFS=$'\n\t'; arch_list_csv_normalize 'amd64, arm64, riscv64, 386')" \
  "space-separated input + 386 alias also normalize to CSV under a strict caller IFS"

t_summary
