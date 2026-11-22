#!/usr/bin/env bash
# Generated wrappers run an argv recorder; this does not prove real linking, target execution or image acceptance.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/arch-mapping.sh"
t_private_tmpdir
work="$(t_mktemp -d)"
subject="${1:-${TESTS_DIR}/../02-toolchain/llvm.sh}"
callback="$(t_fn_src "${subject}" _llvm_install_cross_clang_wrapper)" || exit 1
callback="${callback//\/usr\/local\/bin/${work}\/bin}"
eval "${callback//\"\/usr\//\"${work}\/target\/}"
mkdir -p "${work}/bin" "${work}/target"
export LLVM_WRAPPER_ARGV="${work}/argv"
host_clang="${work}/compiler with spaces"
export host_clangxx="${host_clang}"
export gcc_prefix=/fixture-gcc
cat > "${host_clang}" <<'RECORDER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${LLVM_WRAPPER_ARGV}"
RECORDER
chmod +x "${host_clang}"
log() { :; }
die() { printf '%s\n' "$*" >&2; return 1; }
build_arch_oci() { printf '%s' "${fixture_host}"; }
for arch in amd64 arm64 riscv64; do
  mkdir -p "${work}/target/$(arch_deb_multiarch_triplet_for "${arch}")"
done
for fixture_host in amd64 arm64 riscv64; do
  for target in amd64 arm64 riscv64; do
    t_case "${fixture_host} host / ${target} target uses one filesystem root"
    status=0
    _llvm_install_cross_clang_wrapper "${target}" > "${work}/stdout" 2> "${work}/stderr" || status=$?
    t_assert_eq 0 "${status}"
    for driver in clang clang++; do
      wrapper="${work}/bin/${driver}-${target}"
      t_assert_ok test -x "${wrapper}"
      t_assert_ok "${wrapper}" --fixture-option 'argument with spaces'
      expected="$(printf '%s\n' "--target=$(arch_deb_multiarch_triplet_for "${target}")" --sysroot=/ --gcc-toolchain=/fixture-gcc --fixture-option 'argument with spaces')"
      t_assert_eq "${expected}" "$(cat "${LLVM_WRAPPER_ARGV}")"
    done
  done
done

t_case 'missing foreign target tree fails before writing either wrapper'
fixture_host=amd64
rmdir "${work}/target/aarch64-linux-gnu"
command rm -- "${work}/bin/clang-arm64" "${work}/bin/clang++-arm64"
status=0
_llvm_install_cross_clang_wrapper arm64 > "${work}/stdout" 2> "${work}/stderr" || status=$?
t_assert_eq 1 "${status}"
t_assert_contains "$(cat "${work}/stderr")" 'Expected cross target tree not found'
t_assert_fails test -e "${work}/bin/clang-arm64"
t_assert_fails test -e "${work}/bin/clang++-arm64"

t_case 'native wrapper does not require a redundant target tree'
rmdir "${work}/target/x86_64-linux-gnu"
status=0
_llvm_install_cross_clang_wrapper amd64 > "${work}/stdout" 2> "${work}/stderr" || status=$?
t_assert_eq 0 "${status}"
t_summary
