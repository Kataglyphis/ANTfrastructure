#!/usr/bin/env bash
# Compiler lookup order must survive consolidating the C and C++ implementations.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
LIB="${TESTS_DIR}/../01-core/compiler-resolution.sh"
eval "$(t_fn_src "${LIB}" resolve_host_compiler_for_lang)"

resolve_build_gcc_tool() {
  case "$1" in
    "${ACCEPT_TOOL}") printf '/toolchain/%s' "$1" ;;
    *) return 1 ;;
  esac
}

for spec in 'c gcc' 'c cc' 'cxx g++' 'cxx c++'; do
  read -r lang ACCEPT_TOOL <<< "${spec}"
  t_case "${lang} resolves ${ACCEPT_TOOL} from the build-tool resolver"
  t_assert_eq "/toolchain/${ACCEPT_TOOL}" "$(resolve_host_compiler_for_lang "${lang}")"
done

t_case "the primary compiler wins over the alternate"
resolve_build_gcc_tool() { printf '/toolchain/%s' "$1"; }
t_assert_eq /toolchain/gcc "$(resolve_host_compiler_for_lang c)"
t_assert_eq /toolchain/g++ "$(resolve_host_compiler_for_lang cxx)"

t_case "an unknown language fails with an attributable diagnostic"
t_assert_eq "1" "$(t_rc resolve_host_compiler_for_lang rust)"
t_assert_contains "$(t_out resolve_host_compiler_for_lang rust)" 'unknown compiler language "rust"'

t_case "compiler wrappers preserve quoted arguments and the requested tool search path"
eval "$(t_fn_src "${TESTS_DIR}/../01-core/cross-gcc.sh" make_compiler_wrapper)"
eval "$(t_fn_src "${TESTS_DIR}/../01-core/cross-gcc.sh" make_host_compiler_wrapper)"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
_compiler="${_work}/compiler with spaces"
printf '#!/bin/bash\nprintf "ARG=%%s\\n" "$@"\nprintf "ENV=%%s\\n" "$PATH"\n' > "${_compiler}"
chmod +x "${_compiler}"
_host="$(make_host_compiler_wrapper "${_work}/host" "${_compiler}" /host-tools)"
out="$("${_host}" 'argument with spaces')"
t_assert_contains "${out}" ARG=-B/usr/bin/
t_assert_contains "${out}" 'ARG=argument with spaces'
t_assert_contains "${out}" ENV=/host-tools
_target="$(make_compiler_wrapper "${_work}/target" "${_compiler}" /cross-tools/)"
out="$("${_target}" 'argument with spaces')"
t_assert_contains "${out}" ARG=-B/cross-tools/
t_assert_contains "${out}" "ENV=${PATH}"
t_assert_eq 1 "$(t_rc make_compiler_wrapper '' "${_compiler}" /tools)"
t_assert_eq 1 "$(t_rc make_compiler_wrapper "${_work}/invalid" '' /tools)"

eval "$(t_fn_src "${LIB}" _target_gcc_libstdcxx)"
mkdir -p "${_work}/gcc-15/fixture/lib64" "${_work}/gcc-16/fixture/lib"
touch "${_work}/gcc-15/fixture/lib64/libstdc++.so.6.9" \
      "${_work}/gcc-16/fixture/lib/libstdc++.so.6.10" \
      "${_work}/gcc-16/fixture/lib/libstdc++.so.6.10-gdb.py"
t_case "GCC runtime lookup excludes the pretty-printer before version sorting"
t_assert_eq "${_work}/gcc-16/fixture/lib/libstdc++.so.6.10" "$(_target_gcc_libstdcxx fixture "${_work}")"
t_case "GCC runtime lookup returns empty for an unmatched target"
t_assert_eq '' "$(_target_gcc_libstdcxx absent "${_work}")"

t_summary
