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

t_summary
