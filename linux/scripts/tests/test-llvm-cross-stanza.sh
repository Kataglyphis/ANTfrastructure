#!/usr/bin/env bash
# Pins the emitted argv of the 02-toolchain/llvm-cross.sh helpers split out of
# _llvm_cross_setup_and_build. docs/cross-build-verification.md
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
t_assert_contains "${_ss_joined}" "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld"
t_assert_contains "${_ss_joined}" "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
t_assert_contains "${_ss_joined}" "-DLLVM_USE_HOST_TOOLS=ON"
t_assert_contains "${_ss_joined}" "-DCLANG_TABLEGEN=/opt/native/clang-tblgen"

t_case "the NESTED native sub-build gets the host wrappers AND the launcher"
t_assert_contains "${_ss_joined}" \
  "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/w/host-gcc;-DCMAKE_CXX_COMPILER=/w/host-g++;-DCMAKE_ASM_COMPILER=/w/host-gcc;-DCMAKE_C_COMPILER_LAUNCHER=sccache;-DCMAKE_CXX_COMPILER_LAUNCHER=sccache"

t_case "without a launcher the native flags carry no trailing launcher clause"
_ss=()
_llvm_cross_superset_cmake_args _ss /w/host-gcc /w/host-g++ "" /opt/native
t_assert_contains "${_ss[*]}" \
  "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/w/host-gcc;-DCMAKE_CXX_COMPILER=/w/host-g++;-DCMAKE_ASM_COMPILER=/w/host-gcc -DCLANG_TABLEGEN"

# --- the configure argv ------------------------------------------------------
# Stub cmake and capture the full argv the configure helper emits.
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
# launcher args: immediately after -G Ninja, BEFORE -S (they must reach the
# top-level configure, not be appended after the source/binary dirs).
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

t_summary
