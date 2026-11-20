#!/usr/bin/env bash
# Filesystem fixtures prove prefix retention and failures, not real ELF, SDK ABI or GPU execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
t_private_tmpdir
MAT="${TESTS_DIR}/../02-toolchain/materialize-llvm-target.sh"
helper="$(t_fn_src "${MAT}" _llvm_target_preserve_prefixes)" || exit 1
eval "${helper}"

_alias_tree() {
    mkdir -p "$1/bin" "$1/lib"
    printf '%s\n' "$2" > "$1/bin/clang"
    printf '%s\n' "$3" > "$1/lib/libLLVM.so.23.1"
}

_alias_fixture() {
    local root
    root="$(t_mktemp -d)" || return $?
    prefix="${root}/LLVM target"
    _alias_tree "${prefix}" 'selected compiler' 'selected library'
    mkdir -p "${prefix}-unused"
    ln -s "${prefix}-missing" "${prefix}-dangling"
}

while IFS=: read -r host_arch arch; do
    t_case "materialization retains ${host_arch} builder paths for ${arch} target"
    t_needs "real symlinks" t_posix_symlinks
    _alias_fixture
    if [ "${host_arch}" = "${arch}" ]; then
        _alias_tree "${prefix}-${arch}" 'old compiler' 'old library'
    else
        _alias_tree "${prefix}-${host_arch}" 'native compiler' 'native library'
        ln -s "${prefix}-missing" "${prefix}-${arch}"
    fi
    external="${prefix%/*}/cmake-clang"
    ln -s "${prefix}-${arch}/bin/clang" "${external}"
    ln -s "${prefix}-${arch}/lib/libLLVM.so.23.1" "${external}-library"
    t_assert_ok _llvm_target_preserve_prefixes "${prefix}" "${arch}" "${host_arch}"
    t_assert_ok test -L "${prefix}-${arch}"
    t_assert_eq "${prefix}" "$(readlink "${prefix}-${arch}")"
    t_assert_eq 'selected compiler' "$(cat "${prefix}-${arch}/bin/clang")"
    t_assert_eq 'selected library' "$(cat "${prefix}-${arch}/lib/libLLVM.so.23.1")"
    t_assert_eq 'selected compiler' "$(cat "${external}")"
    t_assert_eq 'selected library' "$(cat "${external}-library")"
    t_assert_ok test ! -e "${prefix}-unused"
    t_assert_ok test ! -L "${prefix}-dangling"
    if [ "${host_arch}" != "${arch}" ]; then
        t_assert_eq 'native compiler' "$(cat "${prefix}-${host_arch}/bin/clang")"
        t_assert_eq 'native library' "$(cat "${prefix}-${host_arch}/lib/libLLVM.so.23.1")"
        t_assert_ok test ! -L "${prefix}-${host_arch}"
    fi
done <<'TARGETS'
amd64:amd64
arm64:arm64
riscv64:riscv64
amd64:arm64
arm64:riscv64
riscv64:amd64
TARGETS

t_case "failed cleanup preserves its raw status and never creates an alias"
_alias_fixture
trace="${prefix%/*}/trace"
rm() { return 47; }
ln() { printf 'unexpected alias\n' >> "${trace}"; return 0; }
status=0
_llvm_target_preserve_prefixes "${prefix}" amd64 amd64 || status=$?
unset -f rm ln
t_assert_eq 47 "${status}"
t_assert_ok test ! -e "${trace}"

t_case "alias creation failures retain their raw status for conditional callers"
_alias_fixture
ln() { return 53; }
status=0
_llvm_target_preserve_prefixes "${prefix}" arm64 amd64 || status=$?
unset -f ln
t_assert_eq 53 "${status}"

t_case "the SDK uses the shared preservation after materialization"
t_assert_contains "$(cat "${MAT}")" '_llvm_target_preserve_prefixes /opt/llvm-target "${_arch}" "${_host_arch}"'
t_summary
