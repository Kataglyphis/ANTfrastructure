#!/usr/bin/env bash
# The argv of llvm-cross.sh's helpers split out of _llvm_cross_setup_and_build; see docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../02-toolchain/llvm-cross.sh"

_FIX="$(mktemp -d)"
trap 'rm -rf "${_FIX}"' EXIT
mkdir -p "${_FIX}/liba" "${_FIX}/libb"

# --- rpath-link linker flags -------------------------------------------------
llvm_cross_target_runtime_library_path() { printf '%s\n' "${STUB_RUNTIME_PATH:-}"; }

t_case "linker flag args carry one -Wl,-rpath-link per EXISTING dir, in order"
STUB_RUNTIME_PATH="${_FIX}/liba:${_FIX}/nope:${_FIX}/libb"
_lf=()
_llvm_cross_linker_flag_args _lf arm64
t_assert_eq "3" "${#_lf[@]}" "exe/shared/module linker flags must all be emitted"
t_assert_eq "-DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,-rpath-link,${_FIX}/liba -Wl,-rpath-link,${_FIX}/libb" "${_lf[0]}"
t_assert_eq "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-Wl,-rpath-link,${_FIX}/liba -Wl,-rpath-link,${_FIX}/libb" "${_lf[1]}"
t_assert_eq "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-Wl,-rpath-link,${_FIX}/liba -Wl,-rpath-link,${_FIX}/libb" "${_lf[2]}"

t_case "no runtime library path -> no linker flag args at all"
STUB_RUNTIME_PATH=""
_lf=(stale)
_llvm_cross_linker_flag_args _lf arm64
t_assert_eq "0" "${#_lf[@]}" "the out array must be reset, not appended to"

t_case "a runtime path whose dirs are all absent yields no linker flag args"
STUB_RUNTIME_PATH="${_FIX}/nope:${_FIX}/also-nope"
_lf=(stale)
_llvm_cross_linker_flag_args _lf riscv64
t_assert_eq "0" "${#_lf[@]}"

t_case "a failing runtime-path resolver is tolerated (|| true), not fatal"
llvm_cross_target_runtime_library_path() { return 6; }
_lf=(stale)
t_assert_ok _llvm_cross_linker_flag_args _lf riscv64
t_assert_eq "0" "${#_lf[@]}"
llvm_cross_target_runtime_library_path() { printf '%s\n' "${STUB_RUNTIME_PATH:-}"; }

# compiler-rt's dir is named by the configured triple, clang searches the normalized one: each arch is pinned by name.
source "${TESTS_DIR}/../01-core/platform.sh"

t_case "every arch normalizes to the LLVM vendor spelling, amd64 included"
t_assert_eq "x86_64-unknown-linux-gnu" "$(llvm_cross_clang_triple x86_64-linux-gnu)" \
  "amd64 is the arm that was missing, and the only arch that shipped a clang with no runtime dir"
t_assert_eq "aarch64-unknown-linux-gnu" "$(llvm_cross_clang_triple aarch64-linux-gnu)"
t_assert_eq "riscv64-unknown-linux-gnu" "$(llvm_cross_clang_triple riscv64-linux-gnu)"
t_assert_eq "i386-unknown-linux-gnu" "$(llvm_cross_clang_triple i386-linux-gnu)" \
  "the mapping is derived, so an arch no list mentions is normalized too"

t_case "the triplet platform.sh hands the build maps, for every arch it knows"
# Walks the same source the build does, so a new arch cannot arrive on the Debian spelling.
for _a in amd64 arm64 riscv64; do
  _deb="$(arch_deb_multiarch_triplet_for "${_a}")"
  _llvm="$(llvm_cross_clang_triple "${_deb}")" || _llvm="REFUSED"
  t_assert_eq "${_deb%-linux-gnu}-unknown-linux-gnu" "${_llvm}" \
    "${_a}: ${_deb} must reach the vendor spelling the driver searches"
done

t_case "an already-normalized triple passes through unchanged"
t_assert_eq "x86_64-unknown-linux-gnu" "$(llvm_cross_clang_triple x86_64-unknown-linux-gnu)"

t_case "a string that is not a Debian multiarch triplet is REFUSED"
# `|| _rc=$?`: the sourced llvm-cross.sh sets -e, which would kill a `$(...; echo $?)` before the echo.
_rc=0; llvm_cross_clang_triple nonsense >/dev/null 2>&1 || _rc=$?
t_assert_eq "1" "${_rc}" \
  "falling through to the input is exactly how amd64 shipped the wrong directory"
_rc=0; llvm_cross_clang_triple -linux-gnu >/dev/null 2>&1 || _rc=$?
t_assert_eq "1" "${_rc}" "an empty arch field is not a triplet"

# --- compiler-cache launcher args -------------------------------------------
t_case "no usable launcher -> no launcher args"
_cl=(stale)
_llvm_cross_launcher_cmake_args _cl ""
t_assert_eq "0" "${#_cl[@]}"

t_case "a launcher sets BOTH the C and the C++ launcher"
_cl=()
_llvm_cross_launcher_cmake_args _cl sccache
t_assert_eq "2" "${#_cl[@]}"
t_assert_eq "-DCMAKE_C_COMPILER_LAUNCHER=sccache" "${_cl[0]}"
t_assert_eq "-DCMAKE_CXX_COMPILER_LAUNCHER=sccache" "${_cl[1]}"

# --- superset shape ----------------------------------------------------------
t_case "superset args keep the projects/runtimes shape (NOT the core-only one)"
_ss=()
_llvm_cross_superset_cmake_args _ss /w/host-gcc /w/host-g++ sccache /opt/native
_ss_joined="${_ss[*]}"
t_assert_contains "${_ss_joined}" "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb "
t_assert_contains "${_ss_joined}" "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
t_assert_contains "${_ss_joined}" "-DLLVM_USE_HOST_TOOLS=ON"
t_assert_contains "${_ss_joined}" "-DCLANG_TABLEGEN=/opt/native/clang-tblgen"

t_case "lldb builds with nothing the cross sysroot lacks (CON71)"
for _off in PYTHON LUA LIBEDIT CURSES LZMA; do
  t_assert_contains "${_ss_joined}" "-DLLDB_ENABLE_${_off}=OFF"
done

t_case "the NESTED native sub-build gets the host wrappers AND the launcher"
t_assert_contains "${_ss_joined}" \
  "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/w/host-gcc;-DCMAKE_CXX_COMPILER=/w/host-g++;-DCMAKE_ASM_COMPILER=/w/host-gcc;-DCMAKE_C_COMPILER_LAUNCHER=sccache;-DCMAKE_CXX_COMPILER_LAUNCHER=sccache"

t_case "without a launcher the native flags carry no trailing launcher clause"
_ss=()
_llvm_cross_superset_cmake_args _ss /w/host-gcc /w/host-g++ "" /opt/native
t_assert_contains "${_ss[*]}" \
  "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/w/host-gcc;-DCMAKE_CXX_COMPILER=/w/host-g++;-DCMAKE_ASM_COMPILER=/w/host-gcc -DCLANG_TABLEGEN"

# The configure argv, captured by a stub cmake.
_CMAKE_ARGV=""
cmake() { _CMAKE_ARGV="$*"; }

export CROSS_TARGET_PROCESSOR=aarch64 CROSS_TARGET_TRIPLET=aarch64-linux-gnu CMAKE_SYSROOT=/sysroot
export CC=xcc CXX=xcxx AR=xar RANLIB=xranlib NM=xnm OBJCOPY=xobjcopy STRIP=xstrip

declare -A _cfg_state=(
  [source_dir]=/src/llvm-project
  [build_dir]=/build/aarch64-linux-gnu
  [prefix]=/opt/llvm-target-arm64
  [wrapper_dir]=/build/aarch64-linux-gnu-tool-bin
  [backend]=AArch64
  [native_tool_dir]=/opt/native
  [jobs]=7
  [llvm_prefix]=/opt/llvm-cross/aarch64-linux-gnu
)
_cfg_launcher=(-DCMAKE_C_COMPILER_LAUNCHER=sccache)
_cfg_linker=(-DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,-rpath-link,/lib)
_cfg_superset=(-DLLVM_ENABLE_PROJECTS=clang)
_llvm_cross_cmake_configure _cfg_state aarch64-unknown-linux-gnu \
  _cfg_launcher _cfg_linker _cfg_superset

t_case "configure passes the cross toolchain binaries from the exported env"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_C_COMPILER=xcc -DCMAKE_CXX_COMPILER=xcxx -DCMAKE_ASM_COMPILER=xcc"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_AR=xar -DCMAKE_RANLIB=xranlib -DCMAKE_NM=xnm -DCMAKE_OBJCOPY=xobjcopy -DCMAKE_STRIP=xstrip"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_SYSTEM_PROCESSOR=aarch64"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_LIBRARY_ARCHITECTURE=aarch64-linux-gnu"

t_case "the three injected arg groups land at their original insertion points"
# launcher args: after -G Ninja and before -S, so they reach the top-level configure.
t_assert_contains "${_CMAKE_ARGV}" "-G Ninja -DCMAKE_C_COMPILER_LAUNCHER=sccache -S /src/llvm-project/llvm -B /build/aarch64-linux-gnu"
# linker args: between CMAKE_STRIP and the -B<wrapper_dir> flag inits.
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_STRIP=xstrip -DCMAKE_EXE_LINKER_FLAGS_INIT=-Wl,-rpath-link,/lib -DCMAKE_C_FLAGS_INIT=-B/build/aarch64-linux-gnu-tool-bin"
# superset args: between LLVM_TARGETS_TO_BUILD and the dylib switches.
t_assert_contains "${_CMAKE_ARGV}" "-DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_ENABLE_PROJECTS=clang -DLLVM_BUILD_LLVM_DYLIB=ON"

t_case "configure keeps the cross find-root modes and the native tablegen wiring"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
t_assert_contains "${_CMAKE_ARGV}" "-DLLVM_HOST_TRIPLE=aarch64-unknown-linux-gnu -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-unknown-linux-gnu"
t_assert_contains "${_CMAKE_ARGV}" "-DLLVM_NATIVE_TOOL_DIR=/opt/native -DLLVM_TABLEGEN=/opt/native/llvm-tblgen"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_INSTALL_PREFIX=/opt/llvm-target-arm64"

t_case "the utilities (FileCheck, yaml2obj, llvm-tblgen) are built and installed with the release (CON71)"
t_assert_contains "${_CMAKE_ARGV}" "-DLLVM_INCLUDE_UTILS=ON -DLLVM_BUILD_UTILS=ON -DLLVM_INSTALL_UTILS=ON"

t_case "without staged zlib headers the flag inits stay -B<wrapper_dir> alone"
t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_CXX_FLAGS_INIT=-B/build/aarch64-linux-gnu-tool-bin -DCMAKE_ASM_FLAGS_INIT"

t_case "lldb's CTF plugin finds zlib.h: the staged dir holds only zlib's two headers and reaches every flag init"
mkdir -p "${_FIX}/sysroot/usr/include"
printf 'z\n' > "${_FIX}/sysroot/usr/include/zlib.h"
printf 'c\n' > "${_FIX}/sysroot/usr/include/zconf.h"
printf 's\n' > "${_FIX}/sysroot/usr/include/stdio.h"
llvm_cross_stage_zlib_headers "${_FIX}/zinc" "${_FIX}/sysroot/"
t_assert_eq "zconf.h zlib.h" "$(cd "${_FIX}/zinc" && echo *)" "a host header beside them would shadow the target's"
_cfg_state[zlib_include]="${_FIX}/zinc"
_llvm_cross_cmake_configure _cfg_state aarch64-unknown-linux-gnu \
  _cfg_launcher _cfg_linker _cfg_superset
for _l in C CXX ASM; do
  t_assert_contains "${_CMAKE_ARGV}" "-DCMAKE_${_l}_FLAGS_INIT=-B/build/aarch64-linux-gnu-tool-bin -isystem ${_FIX}/zinc"
done
unset '_cfg_state[zlib_include]'
llvm_cross_stage_zlib_headers "${_FIX}/zinc" "${_FIX}/empty"
t_assert_eq "absent" "$([ -e "${_FIX}/zinc" ] && echo present || echo absent)" "no zlib in the sysroot leaves no stale dir behind"

# --- build + install ---------------------------------------------------------
_CMAKE_CALLS=()
cmake() { _CMAKE_CALLS+=("$*"); }
_llvm_cross_build_and_install _cfg_state

t_case "the tree is built, llvm-config is forced, and BOTH prefixes are installed"
t_assert_eq "4" "${#_CMAKE_CALLS[@]}"
t_assert_eq "--build /build/aarch64-linux-gnu --parallel 7" "${_CMAKE_CALLS[0]}"
# TVM consumes llvm-config out of /opt/llvm-cross; "all" does not guarantee it.
t_assert_eq "--build /build/aarch64-linux-gnu --parallel 7 --target llvm-config" "${_CMAKE_CALLS[1]}"
# --strip on BOTH installs: the cross CMAKE_STRIP, or the tree is multiple GB.
t_assert_eq "--install /build/aarch64-linux-gnu --strip" "${_CMAKE_CALLS[2]}"
t_assert_eq "--install /build/aarch64-linux-gnu --strip --prefix /opt/llvm-cross/aarch64-linux-gnu" "${_CMAKE_CALLS[3]}"

# Host-as-target: setup_linux_cross_env exports nothing, so configure must still build a complete argv.
_stanza_scenario() {
  # $1 = target triplet, $2 = build triplet (equal: host-as-target), copied before the stubs shadow $2.
  bash -c '
    set -u
    _TT="$1"; _BT="$2"
    source linux/scripts/02-toolchain/llvm-cross.sh 2>/dev/null
    _CMAKE_ARGV=""; cmake() { _CMAKE_ARGV="$*"; }
    # llvm-cross.sh is sourced standalone here, without common.sh: supply the
    # one helper the resolver needs so its refusal is observable, not a 127.
    die() { printf "%s\n" "$*" >&2; exit 1; }
    require_cross_gcc_tool()          { return 1; }
    resolve_build_gcc_tool()          { printf "/usr/bin/%s" "$1"; }
    arch_cmake_system_processor_for() { printf "x86_64"; }
    build_deb_multiarch_triplet()     { printf "%s" "${_BT}"; }
    declare -A st=([source_dir]=/s [build_dir]=/b [prefix]=/p [wrapper_dir]=/w
                   [backend]=X86 [native_tool_dir]=/n [jobs]=1 [llvm_prefix]=/l
                   [target_label]=amd64 [triplet]="${_TT}")
    a=(); b=(); c=()
    _llvm_cross_cmake_configure st some-triple a b c
    printf "%s" "${_CMAKE_ARGV}"
  ' _ "$1" "$2" 2>&1
}

# One scrub list, so neither case passes on the CC=xcc this suite exported earlier.
_stanza_scrubbed() {
  env -u CC -u CXX -u AR -u AS -u LD -u NM -u RANLIB -u STRIP -u OBJCOPY \
      -u CLANG -u CLANGXX -u CROSS_TARGET_TRIPLET -u CROSS_TARGET_PROCESSOR \
      -u CROSS_RUST_TARGET -u CMAKE_SYSROOT -u LIBRARY_PATH \
      bash -c "$(declare -f _stanza_scenario)"'; _stanza_scenario "$1" "$2"' _ "$1" "$2" || true
}

t_case "configure resolves its own toolchain when the cross env exported nothing"
_HOST_ARGV="$(_stanza_scrubbed x86_64-linux-gnu x86_64-linux-gnu)"
t_assert_contains "${_HOST_ARGV}" "-DCMAKE_C_COMPILER=/usr/bin/gcc" \
  "an unset cross env is a legitimate state here, not an unbound-variable abort"
t_assert_contains "${_HOST_ARGV}" "-DCMAKE_AR=/usr/bin/ar"
t_assert_contains "${_HOST_ARGV}" "-DCMAKE_SYSTEM_PROCESSOR=x86_64"
t_assert_contains "${_HOST_ARGV}" "-DCMAKE_LIBRARY_ARCHITECTURE=x86_64-linux-gnu"
# An empty -D<NAME>= is the silent failure this replaced: cmake accepts it.
t_assert_eq "0" "$(printf '%s' "${_HOST_ARGV}" | grep -oE -e '-D[A-Z_]+= ' | wc -l | tr -d ' ')" \
  "no cmake define may be handed an empty value"

t_case "a foreign target gets NO host fallback — it dies naming the tool"
_FT_OUT="$(_stanza_scrubbed aarch64-linux-gnu x86_64-linux-gnu)"
t_assert_contains "${_FT_OUT}" "no host fallback is allowed" \
  "silently substituting the BUILD host's gcc for a foreign target is how a cross image ships the wrong ELF"
t_assert_eq "0" "$(printf '%s' "${_FT_OUT}" | grep -c -e '-DCMAKE_C_COMPILER=/usr/bin/gcc' || true)" \
  "the host compiler must never reach a foreign target's configure"

# With target == build host nothing is exported, so any unguarded read of the surface is a future abort.
t_case "no unguarded read of the cross-env export surface in the host-as-target path"
_LC="${TESTS_DIR}/../02-toolchain/llvm-cross.sh"
# What _cross_env_export_all (cross-env.sh) exports; kept beside the assertion so it grows with it.
_SURFACE='CC CXX AR AS LD NM RANLIB STRIP OBJCOPY CLANG CLANGXX
CROSS_TARGET_TRIPLET CROSS_TARGET_PROCESSOR CROSS_RUST_TARGET
CMAKE_SYSROOT CMAKE_AR CMAKE_RANLIB CMAKE_NM CMAKE_STRIP CMAKE_OBJCOPY
PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG_ALLOW_CROSS LIBRARY_PATH
CARGO_BUILD_TARGET PYTHON_CROSS_ROOT'
_scan_fn() {
  # body of $1, comments stripped
  sed -n "/^$1()/,/^}/p" "${_LC}" | sed 's/[[:space:]]*#.*$//'
}
_unguarded=""
for _fn in _llvm_cross_cmake_configure _llvm_cross_setup_and_build; do
  _body="$(_scan_fn "${_fn}")"
  for _n in ${_SURFACE}; do
    # ${NAME} or ${NAME[^:-]... — a guarded read is ${NAME:-...} or ${NAME:?...}
    if printf '%s' "${_body}" | grep -qE '\$\{'"${_n}"'\}'; then
      _unguarded="${_unguarded} ${_fn}:${_n}"
    fi
  done
done
t_assert_eq "" "${_unguarded}" \
  "each of these is a build cycle: the cross env exports nothing when the target IS the build host"

t_summary
