#!/usr/bin/env bash
# The package stage's clang wiring, off-target against a fake LLVM tree:
#   write_clang_gcc_toolchain_cfg   the cfg pair beside every link to the driver (BACKLOG CON16, CON39)
#   link_compiler_rt_legacy_names   the lib/linux names atheris probes for (CON38)
#   _smoke_atheris_libfuzzer_probe  validate-compilers.sh's port of atheris' find_libfuzzer.sh
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WIRING="${TESTS_DIR}/../06-packaging/package-image-wiring.sh"
VALIDATE="${TESTS_DIR}/../06-packaging/validate-compilers.sh"

_fns=""
for _f in write_clang_gcc_toolchain_cfg link_compiler_rt_legacy_names; do
  _src="$(t_fn_src "${WIRING}" "${_f}")" || exit 1
  _fns+="${_src}"$'\n'
done
_probe="$(t_fn_src "${VALIDATE}" _smoke_atheris_libfuzzer_probe)" || exit 1
_tidy="$(t_fn_src "${VALIDATE}" _smoke_clang_gcc_toolchain)" || exit 1
_tidy+=$'\n'"$(t_fn_src "${VALIDATE}" _smoke_gcc_selection)" || exit 1

_w="$(mktemp -d)"; trap 'rm -rf "${_w}"' EXIT
_rt="${_w}/llvm/lib/clang/23"
_tt="x86_64-unknown-linux-gnu"
mkdir -p "${_w}/llvm/bin" "${_w}/usr/bin" "${_w}/usr/local/bin" "${_w}/gcc/lib/gcc" "${_rt}/lib/${_tt}" "${_w}/stub"
cat > "${_w}/llvm/bin/clang-23" <<FAKE
#!/usr/bin/env bash
case "\$1" in
  -print-target-triple) echo ${_tt} ;;
  -print-resource-dir) echo ${_rt} ;;
  -print-search-dirs) echo "programs: =${_w}/llvm/bin"; echo "libraries: =${_w}/gcc/lib:${_rt}:${_rt}/lib/${_tt}" ;;
esac
FAKE
chmod +x "${_w}/llvm/bin/clang-23"
ln -s clang-23 "${_w}/llvm/bin/clang"; ln -s clang-23 "${_w}/llvm/bin/clang++"
ln -s ../../llvm/bin/clang "${_w}/usr/bin/clang"; ln -s ../../llvm/bin/clang++ "${_w}/usr/bin/clang++"
ln -s ../../../llvm/bin/clang-23 "${_w}/usr/local/bin/clang-23"
ln -s /bin/true "${_w}/usr/local/bin/unrelated"
# The per-target runtimes, fuzzer_no_main in TheRock's suffixed spelling and one sanitizer missing.
for _a in fuzzer fuzzer_interceptors asan ubsan_standalone; do : > "${_rt}/lib/${_tt}/libclang_rt.${_a}.a"; done
: > "${_rt}/lib/${_tt}/libclang_rt.fuzzer_no_main-x86_64.a"

_wire() { GCC_PREFIX="${_w}/gcc" bash -c "${_fns}"$'\n'"$1" 2>&1; }

t_case "the cfg pair lands beside the real driver and in every directory that links to it"
_out="$(_wire "write_clang_gcc_toolchain_cfg '${_w}/usr/bin/clang' '${_w}/usr/bin' '${_w}/usr/local/bin'")"
for _d in llvm/bin usr/bin usr/local/bin; do
  for _drv in clang clang++; do
    t_assert_eq "--gcc-toolchain=${_w}/gcc" "$(cat "${_w}/${_d}/${_tt}-${_drv}.cfg" 2>/dev/null)" "${_d}/${_drv}"
  done
done
t_assert_contains "${_out}" "OK: ${_w}/usr/bin/${_tt}-clang{,++}.cfg"

t_case "a directory with no link to the driver gets no cfg"
mkdir -p "${_w}/nolink"; ln -s /bin/true "${_w}/nolink/clang"
_wire "write_clang_gcc_toolchain_cfg '${_w}/usr/bin/clang' '${_w}/nolink'" >/dev/null
t_assert_fails test -e "${_w}/nolink/${_tt}-clang.cfg"

t_case "a GCC_PREFIX without a GCC is refused"
t_assert_eq "1" "$(GCC_PREFIX="${_w}/usr" bash -c "${_fns}"$'\n'"write_clang_gcc_toolchain_cfg '${_w}/usr/bin/clang' >/dev/null 2>&1; echo \$?")"

t_case "every runtime atheris names gets its lib/linux name, from either per-target spelling"
_out="$(_wire "link_compiler_rt_legacy_names '${_w}/usr/bin/clang'")"
for _a in fuzzer fuzzer_no_main fuzzer_interceptors asan ubsan_standalone; do
  t_assert_ok test -f "${_rt}/lib/linux/libclang_rt.${_a}-x86_64.a"
done
t_assert_eq "../${_tt}/libclang_rt.fuzzer_no_main-x86_64.a" "$(readlink "${_rt}/lib/linux/libclang_rt.fuzzer_no_main-x86_64.a")"
t_assert_contains "${_out}" "no libclang_rt.ubsan_standalone_cxx"
t_assert_fails test -e "${_rt}/lib/linux/libclang_rt.ubsan_standalone_cxx-x86_64.a"

# _atheris <uname -m>: the smoke with uname, objdump and validate_fail stubbed, clang the fake.
printf '#!/bin/sh\necho "0000 g F .text 0000 LLVMFuzzerRunDriver"\n' > "${_w}/stub/objdump"
chmod +x "${_w}/stub/objdump"
_atheris() {
  PATH="${_w}/stub:${_w}/usr/bin:${PATH}" MACHINE="$1" bash -c '
    uname() { echo "${MACHINE}"; }
    validate_fail() { echo "FAIL [$1]: $2"; }
    '"${_probe}"'
    _smoke_atheris_libfuzzer_probe' 2>&1
}

t_case "atheris' probe finds the legacy name, but reports the sanitizer it would merge and is missing"
_out="$(_atheris x86_64)"
t_assert_contains "${_out}" "FAIL [atheris-libfuzzer]: no ${_rt}/lib/linux/libclang_rt.ubsan_standalone_cxx-x86_64.a"
: > "${_rt}/lib/${_tt}/libclang_rt.ubsan_standalone_cxx.a"
_wire "link_compiler_rt_legacy_names '${_w}/usr/bin/clang'" >/dev/null
t_assert_eq "SMOKE OK: atheris' probe finds ${_rt}/lib/linux/libclang_rt.fuzzer_no_main-x86_64.a" "$(_atheris x86_64)"

t_case "the per-target layout alone is what atheris cannot find"
rm -rf "${_rt}/lib/linux"
t_assert_contains "$(_atheris x86_64)" "FAIL [atheris-libfuzzer]: atheris' probe finds no lib/linux/libclang_rt.fuzzer_no_main-x86_64.a"

t_case "an arch atheris' probe does not know is a note, not a failure"
t_assert_contains "$(_atheris riscv64)" "SMOKE NOTE: atheris' probe knows no riscv64"

t_case "the smoke grades clang-tidy's GCC per /usr/bin name, not only the bare driver's"
cat > "${_w}/stub/clang++" <<FAKE
#!/bin/sh
echo "Selected GCC installation: ${_w}/gcc/lib/gcc/x86_64-pc-linux-gnu/16.2.0" >&2
FAKE
cat > "${_w}/stub/clang-tidy" <<'FAKE'
#!/bin/sh
case "$(cat "$2/compile_commands.json")" in
  *'"/usr/bin/clang++ '*) echo "Selected GCC installation: /usr/bin/../lib/gcc/x86_64-linux-gnu/16" ;;
  *) echo "Selected GCC installation: ${GCC_PREFIX}/lib/gcc/x86_64-pc-linux-gnu/16.2.0" ;;
esac
FAKE
chmod +x "${_w}/stub/clang++" "${_w}/stub/clang-tidy"
_out="$(PATH="${_w}/stub:${PATH}" GCC_PREFIX="${_w}/gcc" bash -c '
  validate_fail() { echo "FAIL [$1]: $2"; }
  '"${_tidy}"'
  _smoke_clang_gcc_toolchain' 2>&1)"
t_assert_contains "${_out}" "SMOKE OK: bare clang++ selects ${_w}/gcc/"
t_assert_contains "${_out}" "SMOKE OK: clang-tidy via /usr/bin/clang selects ${_w}/gcc/"
t_assert_contains "${_out}" "FAIL [clang-gcc-toolchain]: clang-tidy via /usr/bin/clang++ selects '/usr/bin/../lib/gcc/x86_64-linux-gnu/16'"

t_summary
