#!/usr/bin/env bash
# The package stage's clang wiring on a fake LLVM tree: the pinned tool names, the toolchain cfg pair, atheris' legacy compiler-rt names; its GTK 4 gate.
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

t_case "a Vulkan SDK name that shadows the pinned LLVM is renamed; the SDK's own tools stay (CON71)"
_vk="${_w}/vk"
mkdir -p "${_vk}/1.4.363.0/x86_64/bin"
for _t in FileCheck glslangValidator dxc; do printf '#!/bin/sh\n' > "${_vk}/1.4.363.0/x86_64/bin/${_t}"; done
chmod +x "${_vk}/1.4.363.0/x86_64/bin"/*
: > "${_vk}/1.4.363.0/x86_64/bin/lldb"
ln -s 1.4.363.0/x86_64 "${_vk}/active"
_unsrc="$(t_fn_src "${WIRING}" unshadow_pinned_llvm_tools)" || exit 1
_out="$(bash -c "${_unsrc}"'
  unshadow_pinned_llvm_tools "$1" "$2"' _ "${_p}/target/bin" "${_vk}/active/bin" 2>&1)"
t_assert_contains "${_out}" "1 Vulkan SDK name(s) that shadowed the pinned LLVM renamed to vulkan-sdk-<name>: FileCheck"
t_assert_fails test -e "${_vk}/active/bin/FileCheck"
t_assert_ok test -x "${_vk}/active/bin/vulkan-sdk-FileCheck"
for _t in glslangValidator dxc lldb; do t_assert_ok test -e "${_vk}/active/bin/${_t}"; done
_out="$(bash -c "${_unsrc}"'
  unshadow_pinned_llvm_tools "$1" "$2"' _ "${_p}/target/bin" "${_w}/no-vulkan/bin" 2>&1)"
t_assert_contains "${_out}" "no Vulkan SDK bin at ${_w}/no-vulkan/bin"

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

# --- the GTK 4 gtk4-rs builds against (CON129) --------------------------------
_g4fns=""
for _f in prefix_gtk4_lib gtk4_dev_packages verify_gtk4_dev_surface; do
  _src="$(t_fn_src "${WIRING}" "${_f}")" || exit 1
  _g4fns+="${_src}"$'\n'
done
mkdir -p "${_w}/gst-gtk/lib/x86_64-linux-gnu" "${_w}/gst-nogtk/lib"
: > "${_w}/gst-gtk/lib/x86_64-linux-gnu/libgtk-4.so.1"
_g4pkgs() { GSTREAMER_PREFIX="$1" bash -c "${_g4fns}"$'\n''gtk4_dev_packages' | paste -sd' ' -; }

t_case "a prefix with its own GTK 4 gets the two dev packages its gtk4.pc lacks, any other image the distro's"
t_assert_eq "libgraphene-1.0-dev libvulkan-dev" "$(_g4pkgs "${_w}/gst-gtk")" \
  "amd64: the distro libgtk-4-dev would bring back the GStreamer runtime CON21 drops"
t_assert_eq "libgtk-4-dev" "$(_g4pkgs "${_w}/gst-nogtk")" "arm64 and riscv64 run the distro GTK 4"

# _g4 <gtk4 version> <--cflags rc> <ldd output>: the gate over stubbed pkg-config and ldd.
_g4() {
  G4_VER="$1" G4_RC="$2" G4_LDD="$3" bash -c '
    pkg-config() {
      case "$1" in
        --atleast-version=*) [ "$(printf "%s\n%s\n" "${1#*=}" "${G4_VER}" | sort -V | head -n 1)" = "${1#*=}" ] ;;
        --cflags) [ "${G4_RC}" = 0 ] || echo "Package vulkan was not found" >&2; return "${G4_RC}" ;;
        --modversion) echo "${G4_VER}" ;;
        --variable=libdir) echo /usr/lib/x86_64-linux-gnu ;;
      esac
    }
    ldd() { [ "$1" = -r ] || return 2; printf "%s\n" "${G4_LDD}"; }
    '"${_g4fns}"'
    verify_gtk4_dev_surface; echo "rc=$?"' 2>&1
}

t_case "gtk4 at the floor, with every Requires and a library that loads, passes"
_out="$(_g4 4.14.5 0 'libgraphene-1.0.so.0 => /usr/lib/x86_64-linux-gnu/libgraphene-1.0.so.0')"
t_assert_contains "${_out}" "OK: gtk4 4.14.5 at /usr/lib/x86_64-linux-gnu/libgtk-4.so.1"
t_assert_contains "${_out}" "rc=0"

t_case "a gtk4 below gtk4-rs 0.11's v4_10 fails the stage"
_out="$(_g4 4.8.3 0 '')"
t_assert_contains "${_out}" "ERROR: gtk4 >= 4.10 with every Requires is not reachable: 4.8.3"
t_assert_contains "${_out}" "rc=1"

t_case "a gtk4.pc whose Requires do not resolve fails, though --modversion answers"
_out="$(_g4 4.22.4 1 '')"
t_assert_contains "${_out}" "Package vulkan was not found"
t_assert_contains "${_out}" "rc=1"

t_case "a libgtk-4.so.1 with an unresolved NEEDED fails"
_out="$(_g4 4.22.4 0 'libgraphene-1.0.so.0 => not found')"
t_assert_contains "${_out}" "does not load: libgraphene-1.0.so.0 => not found"
t_assert_contains "${_out}" "rc=1"

t_case "a symbol an older GLib lacks fails, though every NEEDED resolves (riscv64's prefix GLib 2.86)"
_out="$(_g4 4.22.4 0 'undefined symbol: g_get_monotonic_time_ns	(/usr/lib/riscv64-linux-gnu/libgtk-4.so.1)')"
t_assert_contains "${_out}" "does not load: undefined symbol: g_get_monotonic_time_ns"
t_assert_contains "${_out}" "rc=1"

t_case "the package stage installs and gates it, and drops the distro GTK 4 by the same test"
_setup="${TESTS_DIR}/../06-packaging/setup-package-image.sh"
t_assert_contains "$(t_fn_src "${_setup}" select_dev_packages)" 'mapfile -t -O "${#_sdp_out[@]}" _sdp_out < <(gtk4_dev_packages)'
t_assert_contains "$(t_fn_src "${_setup}" verify_consumer_dev_surface)" '    verify_gtk4_dev_surface'
t_assert_contains "$(t_fn_src "${WIRING}" drop_redundant_distro_gtk4)" 'ours="$(prefix_gtk4_lib)"'
t_assert_contains "$(t_fn_src "${_setup}" main)" $'    drop_redundant_distro_gtk4\n    yield_older_prefix_glib'

# _glib <prefix GLib version|-> <distro GLib version>: the yield over a fake prefix and distro libdir.
_glibsrc="$(t_fn_src "${WIRING}" yield_older_prefix_glib)" || exit 1
_glib() {
  local g="${_w}/glib-$1-$2" f
  rm -rf "${g}"; mkdir -p "${g}/gst/lib/pkgconfig" "${g}/sys"
  : > "${g}/sys/libglib-2.0.so.0.$2"; ln -s "libglib-2.0.so.0.$2" "${g}/sys/libglib-2.0.so.0"
  : > "${g}/gst/lib/libgstreamer-1.0.so.0.2902.0"; : > "${g}/gst/lib/pkgconfig/gstreamer-1.0.pc"
  if [ "$1" != - ]; then
    for f in glib gobject gio gmodule gthread girepository; do
      : > "${g}/gst/lib/lib${f}-2.0.so.0.$1"; ln -s "lib${f}-2.0.so.0.$1" "${g}/gst/lib/lib${f}-2.0.so.0"
      ln -s "lib${f}-2.0.so.0" "${g}/gst/lib/lib${f}-2.0.so"; : > "${g}/gst/lib/pkgconfig/${f}-2.0.pc"
    done
    : > "${g}/gst/lib/pkgconfig/gio-unix-2.0.pc"
  fi
  GSTREAMER_PREFIX="${g}/gst" bash -c "${_glibsrc}"$'\n''yield_older_prefix_glib "$1"' _ "${g}/sys" 2>&1
  echo "LEFT $(cd "${g}/gst/lib" && find . -type f -o -type l | sort | tr '\n' ' ')"
}

t_case "an older prefix GLib yields to the distro's: libraries and .pc files go, GStreamer stays"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_glib 8600.3 8800.0)"
t_assert_contains "${_out}" "OK: libglib-2.0.so.0.8600.3 left"
t_assert_contains "${_out}" "LEFT ./libgstreamer-1.0.so.0.2902.0 ./pkgconfig/gstreamer-1.0.pc "
t_assert_eq "" "$(grep -oE '(glib|gobject|gio|gmodule|gthread|girepository)[-a-z]*-2\.0' <<< "${_out#*LEFT}")" \
  "no GLib library, link or .pc may survive: half a GLib in the prefix splits the process"

t_case "a prefix GLib as new as the distro's stays: ours wins its soname"
t_needs "real symlinks (ln -s copies under Git Bash)" t_posix_symlinks
_out="$(_glib 8800.0 8800.0)"
t_assert_contains "${_out}" "KEEP: the prefix's libglib-2.0.so.0.8800.0 is not older than"
t_assert_contains "${_out}" "./libglib-2.0.so.0.8800.0"

t_case "a prefix without GLib (amd64, arm64) is left alone"
_out="$(_glib - 8800.0)"
t_assert_contains "${_out}" "KEEP: no GLib in the GStreamer prefix"

t_case "the shipped-image contract row reads the same gate as uid 1001"
_smoke="${TESTS_DIR}/../06-packaging/smoke-runtime-image.sh"
_row="$(t_fn_src "${_smoke}" _consumer_contract_fact)"$'\n'"$(t_fn_src "${_smoke}" _consumer_gtk4_verdict)" || exit 1
_g4row() { bash -c "${_row}"$'\n''_consumer_gtk4_verdict gtk4-dev "$1"' _ "$1"; }
t_assert_eq "OK gtk4-dev gtk4 4.22.4 at /usr/lib/riscv64-linux-gnu/libgtk-4.so.1: every Requires, NEEDED and symbol resolves" \
  "$(_g4row 'FACT gtk4-dev OK: gtk4 4.22.4 at /usr/lib/riscv64-linux-gnu/libgtk-4.so.1: every Requires, NEEDED and symbol resolves')"
t_assert_eq "BAD gtk4-dev ERROR: gtk4 >= 4.10 with every Requires is not reachable: 4.14.5" \
  "$(_g4row 'FACT gtk4-dev ERROR: gtk4 >= 4.10 with every Requires is not reachable: 4.14.5')"
t_assert_contains "$(_g4row 'FACT other x')" "NOFACT gtk4-dev"
t_assert_contains "$(grep '^_CONSUMER_CONTRACT_ROWS=' "${_smoke}")" " gtk4-dev"
t_assert_contains "$(cat "${_smoke}")" "printf 'FACT gtk4-dev %s\n' \"\$(bash -c 'source /opt/scripts/packaging/package-image-wiring.sh && verify_gtk4_dev_surface' 2>&1 | tail -1)\""

t_summary
