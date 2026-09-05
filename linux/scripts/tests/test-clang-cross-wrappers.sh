#!/usr/bin/env bash
# The clang-<arch>/clang++-<arch> wrappers 02-toolchain/llvm.sh writes are the only
# path where clang IS the compiler, so what they bake into their exec line is the
# whole cross contract: target triple, sysroot, and the source-built GCC root.
# docs/linux-cross-builds.md#clang-cross-wrappers
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
SUBJECT="${SCRIPTS_DIR}/02-toolchain/llvm.sh"

_src="$(t_fn_src "${SUBJECT}" _llvm_install_cross_clang_wrapper)" || exit 1
_bin="$(mktemp -d)"
trap 'rm -rf "${_bin}"' EXIT

# _install <target> <gcc_prefix> — run the per-target callback with its enclosing
# scope stubbed and /usr/local/bin redirected into a throwaway dir.
_install() {
  bash -c "set -eu
arch_deb_multiarch_triplet_for() { printf 'x86_64-linux-gnu'; }
die() { printf '%s\n' \"\$*\" >&2; exit 1; }
log() { :; }
host_clang=/usr/bin/clang-20
host_clangxx=/usr/bin/clang++-20
gcc_prefix='$2'
${_src//\/usr\/local\/bin/${_bin}}
_llvm_install_cross_clang_wrapper '$1'"
}

t_case "the wrapper bakes the GCC root, so no env knob has to point clang at it"
t_assert_ok _install amd64 /opt/gcc-16.2.0
t_assert_contains "$(cat "${_bin}/clang-amd64")" "--gcc-toolchain=/opt/gcc-16.2.0" \
  "this is what made export_clang_gcc_toolchain_env redundant; deleted 2026-09-05"
t_assert_contains "$(cat "${_bin}/clang++-amd64")" "--gcc-toolchain=/opt/gcc-16.2.0" \
  "and the C++ wrapper carries it too, not just the C one"

t_case "the wrapper also fixes the target triple and the sysroot"
t_assert_contains "$(cat "${_bin}/clang-amd64")" "--target=x86_64-linux-gnu" \
  "a wrapper without the triple is the host compiler under a cross name"
t_assert_contains "$(cat "${_bin}/clang-amd64")" "--sysroot=/" \
  "amd64 is the one target whose sysroot is the image root"

t_case "both wrappers are executable and exec the selected host clang"
t_assert_ok test -x "${_bin}/clang-amd64"
t_assert_ok test -x "${_bin}/clang++-amd64"
t_assert_contains "$(cat "${_bin}/clang++-amd64")" "exec \"/usr/bin/clang++-20\"" \
  "the wrapper must exec the versioned binary llvm_selected_host_clangxx chose"

t_summary
