#!/usr/bin/env bash
# Tests for 01-core/arch-mapping.sh — per-architecture string mappings used by
# the strict compiler/ELF validation scripts — plus the platform.sh mapping
# tables (backlog T4, the "D2 guard"): the per-arch string tables in
# 01-core/platform.sh are regression magnets (a single-character drift like
# riscv64gc→riscv64 silently produces wrong wheels/toolchains much later), so
# their exact outputs are frozen here.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/platform.sh"
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

# ── platform.sh mapping tables (backlog T4 "D2 guard") ────────────────────────

t_case "arch_linux_platform_tag_for maps the 3 supported wheel arches"
t_assert_eq "linux_x86_64"  "$(arch_linux_platform_tag_for amd64)"
t_assert_eq "linux_aarch64" "$(arch_linux_platform_tag_for arm64)"
t_assert_eq "linux_riscv64" "$(arch_linux_platform_tag_for riscv64)"
t_assert_fails arch_linux_platform_tag_for mips64

t_case "arch_rust_target_triple_for maps all 3 arches (riscv64 keeps the gc suffix)"
t_assert_eq "x86_64-unknown-linux-gnu"  "$(arch_rust_target_triple_for amd64)"
t_assert_eq "aarch64-unknown-linux-gnu" "$(arch_rust_target_triple_for arm64)"
t_assert_eq "riscv64gc-unknown-linux-gnu" "$(arch_rust_target_triple_for riscv64)" \
  "the gc suffix is load-bearing: rustc has no riscv64-unknown-linux-gnu target, a 'cleanup' to drop it breaks every Rust cross stage"
t_assert_fails arch_rust_target_triple_for mips64

t_case "arch_deb_multiarch_triplet_for maps all 3 arches; unknown fails with empty output"
t_assert_eq "x86_64-linux-gnu"  "$(arch_deb_multiarch_triplet_for amd64)"
t_assert_eq "aarch64-linux-gnu" "$(arch_deb_multiarch_triplet_for arm64)"
t_assert_eq "riscv64-linux-gnu" "$(arch_deb_multiarch_triplet_for riscv64)"
t_assert_fails arch_deb_multiarch_triplet_for mips64
t_assert_eq "" "$(arch_deb_multiarch_triplet_for mips64 || true)" \
  "unknown arch must return nonzero AND print nothing (callers do triplet=\$(...) || fallback)"

t_case "arch_cmake_system_processor_for maps all 3 arches (unknown passes through normalized)"
t_assert_eq "x86_64"  "$(arch_cmake_system_processor_for amd64)"
t_assert_eq "aarch64" "$(arch_cmake_system_processor_for arm64)"
t_assert_eq "riscv64" "$(arch_cmake_system_processor_for riscv64)"
t_assert_eq "mips64"  "$(arch_cmake_system_processor_for mips64)" \
  "contract differs from the triplet mappers: unknown arch passes through (no failure)"

# End-to-end: common.sh's cross_wheel_platform_tag = arch_linux_platform_tag_for
# over cross_target_arch. Stub cross_target_arch (normally from cross-env.sh)
# BEFORE sourcing common.sh in a subshell so no cross env is needed; the riscv64
# lane is the one where a wrong tag ships an unusable wheelhouse.
t_case "cross_wheel_platform_tag end-to-end with stubbed cross_target_arch"
t_assert_eq "linux_riscv64" "$(
  cross_target_arch() { printf '%s' riscv64; }
  # shellcheck disable=SC1091
  source "${TESTS_DIR}/../01-core/common.sh"
  cross_wheel_platform_tag
)"
t_assert_eq "linux_aarch64" "$(
  cross_target_arch() { printf '%s' arm64; }
  # shellcheck disable=SC1091
  source "${TESTS_DIR}/../01-core/common.sh"
  cross_wheel_platform_tag
)"

t_summary
