#!/usr/bin/env bash
# The package stage's clang wiring on a fake LLVM tree: the pinned tool names, the toolchain cfg pair, atheris' legacy compiler-rt names.
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
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
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
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
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

# --- every unversioned LLVM name is the pinned release's (CON71) ---------------
_namesrc="$(t_fn_src "${WIRING}" llvm_distro_unversioned_names)" || exit 1
_pinsrc="${_namesrc}"$'\n'"$(t_fn_src "${WIRING}" wire_pinned_llvm_tools)" || exit 1
_versrc="${_namesrc}"$'\n'"$(t_fn_src "${VALIDATE}" _smoke_llvm_tool_versions)" || exit 1
_p="${_w}/pin"
mkdir -p "${_p}/target/bin" "${_p}/usr/lib/llvm-21/bin" "${_p}/usr/bin" "${_p}/usr/local/bin"
for _t in clang-23 clang-tidy clang-format lldb FileCheck; do
  printf '#!/bin/sh\necho "%s version 23.1.1"\n' "${_t}" > "${_p}/target/bin/${_t}"
done
for _t in clang-tidy clang-format bugpoint; do
  printf '#!/bin/sh\necho "%s version 21.1.8"\n' "${_t}" > "${_p}/usr/lib/llvm-21/bin/${_t}"
done
chmod +x "${_p}"/target/bin/* "${_p}"/usr/lib/llvm-21/bin/*
: > "${_p}/target/bin/x86_64-unknown-linux-gnu-clang.cfg"
ln -s clang-23 "${_p}/target/bin/clang"
ln -s ../../target/bin/clang "${_p}/usr/bin/clang"
for _t in clang-tidy clang-format bugpoint; do ln -s "../lib/llvm-21/bin/${_t}" "${_p}/usr/bin/${_t}"; done
ln -s ../lib/llvm-21/bin/clang-tidy "${_p}/usr/bin/clang-tidy-21"
ln -s ../lib/llvm-21/bin/clang-format "${_p}/usr/bin/rust-clang"

# dpkg-divert stubbed as the rename it performs; the log is what got diverted.
_pin() {
  P="${_p}" bash -c '
    dpkg-divert() {
      local div="" add=""
      while [ $# -gt 0 ]; do
        case "$1" in --divert) div="$2"; shift 2 ;; --add) add="$2"; shift 2 ;; *) shift ;; esac
      done
      mv "${add}" "${div}" && echo "${add##*/}" >> "${P}/diverted"
    }
    '"${_pinsrc}"'
    wire_pinned_llvm_tools "${P}/usr/bin/clang" "${P}/usr/bin" "${P}/usr/local/bin" "${P}/stash"' 2>&1
}

t_case "every distro name the pinned LLVM also has points into it, in /usr/bin itself"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_pin)"
for _t in clang-tidy clang-format; do
  t_assert_eq "${_p}/target/bin/${_t}" "$(readlink -f "${_p}/usr/bin/${_t}")" "/usr/bin/${_t}"
done
t_assert_eq "bugpoint clang-format clang-tidy" "$(sort "${_p}/diverted" | paste -sd' ' -)" \
  "exactly the three unversioned distro names are diverted"

t_case "a name the pinned LLVM lacks leaves PATH; -NN aliases and rustc's own stay"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
t_assert_fails test -e "${_p}/usr/bin/bugpoint"
t_assert_ok test -L "${_p}/stash/bugpoint"
_left=""
for _f in "${_p}/usr/bin"/*; do
  case "${_f##*/}" in clang | clang-tidy | clang-format | *-21 | rust-clang) ;; *) _left+="${_f##*/} " ;; esac
done
t_assert_eq "" "${_left}" "the diverted originals sit outside PATH"
t_assert_contains "${_out}" "1 name(s) the pinned LLVM lacks left ${_p}/usr/bin, their -NN alias stays: bugpoint"
t_assert_eq "${_p}/usr/lib/llvm-21/bin/clang-tidy" "$(readlink -f "${_p}/usr/bin/clang-tidy-21")"
t_assert_eq "${_p}/usr/lib/llvm-21/bin/clang-format" "$(readlink -f "${_p}/usr/bin/rust-clang")"

t_case "/usr/local/bin gets every pinned tool /usr/bin does not already resolve to, and no cfg or clang-NN"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
t_assert_eq "${_p}/target/bin/lldb" "$(readlink -f "${_p}/usr/local/bin/lldb")"
t_assert_eq "${_p}/target/bin/FileCheck" "$(readlink -f "${_p}/usr/local/bin/FileCheck")"
for _t in clang clang-23 x86_64-unknown-linux-gnu-clang.cfg; do
  t_assert_fails test -e "${_p}/usr/local/bin/${_t}"
done

# _vers <LLVM_RELEASE>: the smoke over the fake tree, PATH as the image orders it.
_vers() {
  PATH="${_p}/usr/local/bin:${_p}/usr/bin:${PATH}" _VCS_SMOKE_LLVM_VER="$1" P="${_p}" bash -c '
    validate_fail() { echo "FAIL [$1]: $2"; }
    _SMOKE_LLVM_TOOLS="clang-tidy clang-format lldb FileCheck"
    '"${_versrc}"'
    _smoke_llvm_tool_versions "${P}/usr/bin"' 2>&1
}

t_case "the smoke passes the wired tree against LLVM_RELEASE, tool by tool"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_vers 23.1.1)"
for _t in clang-tidy clang-format lldb FileCheck; do
  t_assert_contains "${_out}" "SMOKE OK: ${_t} 23.1.1 == LLVM_RELEASE"
done
t_assert_fails grep -q FAIL <<< "${_out}"

t_case "the smoke grades against the pin, not against whatever clang reports"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
t_assert_contains "$(_vers 23.1.2)" "FAIL [llvm-tool-version]: clang-tidy 23.1.1 is not LLVM_RELEASE 23.1.2"

t_case "the smoke fails a distro LLVM under an unversioned name, and only that"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
ln -s ../lib/llvm-21/bin/clang-tidy "${_p}/usr/bin/llvm-cov"
_out="$(_vers 23.1.1)"
t_assert_contains "${_out}" "FAIL [llvm-tool-distro]: ${_p}/usr/bin/llvm-cov is ${_p}/usr/lib/llvm-21/bin/clang-tidy"
t_assert_eq "1" "$(grep -c 'FAIL \[llvm-tool-distro\]' <<< "${_out}")" "clang-tidy-21 and rust-clang are not failures"

t_summary
