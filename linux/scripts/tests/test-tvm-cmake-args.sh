#!/usr/bin/env bash
# Golden argv for append_tvm_cmake_args (05-frameworks/tvm-config.sh): captured
# byte-for-byte pre-refactor, -D order load-bearing, do NOT tidy the expected
# blocks. Collaborators are all stubs. docs/cross-build-verification.md
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../05-frameworks/tvm-config.sh
source "${TESTS_DIR}/../05-frameworks/tvm-config.sh"

# ── stubbed collaborators ────────────────────────────────────────────────────
STUB_CROSS=0
STUB_LAUNCHER=""
STUB_QNN=""
cross_build_is_active() { [ "${STUB_CROSS}" -eq 1 ]; }
cross_target_triplet()  { printf '%s' "aarch64-linux-gnu"; }
append_cmake_cross_args() {
  local -n _stub_ref="$1"
  _stub_ref+=( -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 )
}
compiler_cache_launcher() { printf '%s' "${STUB_LAUNCHER}"; }
resolve_qnn_sdk() { printf '%s' "${STUB_QNN}"; }
info() { printf 'INFO:%s\n' "$*" >&2; }
# The real die (logging.sh) EXITS; the arg-validation tests below rely on that.
die() { printf 'DIE:%s\n' "$*" >&2; exit 97; }

# Seeds the array like both real call sites, publishes it in GLOBAL _got.
# Not a subshell: TVM_QNN_HOME is set non-locally and would be swallowed.
_got=""
_emit() {
  local -a arr=( -G Ninja )
  append_tvm_cmake_args "$@"
  _got="$(printf '%s\n' "${arr[@]}")"
  printf '%s\n' "${_got}"
}

# ── native-vulkan-off ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "native build, Vulkan OFF, no LLVM_DIR, no launcher, no QNN"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value /usr/bin/llvm-config \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=/usr/bin/llvm-config
EOF
t_assert_eq "${_want}" "${_got}" "native-vulkan-off: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "native-vulkan-off: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── native-vulkan-on ──
STUB_CROSS=0; STUB_LAUNCHER="/usr/bin/sccache"; STUB_QNN=""
unset TVM_QNN_HOME
t_case "Vulkan ON emits all three Vulkan_* flags in LIBRARY, INCLUDE_DIR, SPIRV_TOOLS order"
_emit \
  --out arr \
  --python-module ON \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value /usr/bin/llvm-config \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 1 \
  --use-cuda 0 \
  --use-opencl 0 \
  --spirv-tools-lib /opt/vulkan/lib/libSPIRV-Tools.a \
  --cross-link-flags "" \
  --vulkan-library /opt/vk/lib/libvulkan.so \
  --vulkan-include /opt/vk/include >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=ON
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DCMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache
-DCMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/sccache
-DUSE_VULKAN=ON
-DVulkan_LIBRARY=/opt/vk/lib/libvulkan.so
-DVulkan_INCLUDE_DIR=/opt/vk/include
-DVulkan_SPIRV_TOOLS_LIBRARY=/opt/vulkan/lib/libSPIRV-Tools.a
-DUSE_LLVM=/usr/bin/llvm-config
EOF
t_assert_eq "${_want}" "${_got}" "native-vulkan-on: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "native-vulkan-on: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── cross-linkflags ──
STUB_CROSS=1; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "cross build: cross args, USE_ALTERNATIVE_LINKER=OFF, three *_LINKER_FLAGS"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/aarch64-linux-gnu-gcc \
  --cxx /usr/bin/aarch64-linux-gnu-g++ \
  --llvm-cmake-value OFF \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 \
  --use-cuda 0 \
  --use-opencl 0 \
  --spirv-tools-lib "" \
  --cross-link-flags "-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu" >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
-DCMAKE_EXE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
-DCMAKE_SHARED_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
-DCMAKE_MODULE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
-DCMAKE_C_COMPILER=/usr/bin/aarch64-linux-gnu-gcc
-DCMAKE_CXX_COMPILER=/usr/bin/aarch64-linux-gnu-g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF
t_assert_eq "${_want}" "${_got}" "cross-linkflags: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "cross-linkflags: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── cross-linkflags-ambient ──
STUB_CROSS=1; STUB_LAUNCHER=""; STUB_QNN=""
export CMAKE_EXE_LINKER_FLAGS="-Wl,-exe" CMAKE_SHARED_LINKER_FLAGS="-Wl,-shared" CMAKE_MODULE_LINKER_FLAGS="-Wl,-module"
unset TVM_QNN_HOME
t_case "ambient CMAKE_*_LINKER_FLAGS are appended after the cross search flags"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/aarch64-linux-gnu-gcc \
  --cxx /usr/bin/aarch64-linux-gnu-g++ \
  --llvm-cmake-value OFF \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 \
  --cross-link-flags "-L/usr/lib/aarch64-linux-gnu" >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
-DCMAKE_EXE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-exe
-DCMAKE_SHARED_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-shared
-DCMAKE_MODULE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-module
-DCMAKE_C_COMPILER=/usr/bin/aarch64-linux-gnu-gcc
-DCMAKE_CXX_COMPILER=/usr/bin/aarch64-linux-gnu-g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF
t_assert_eq "${_want}" "${_got}" "cross-linkflags-ambient: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "cross-linkflags-ambient: TVM_QNN_HOME (non-local; tvm.sh stages from it)"
unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS

# ── cross-nolinkflags ──
STUB_CROSS=1; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "cross build with empty --cross-link-flags emits NO *_LINKER_FLAGS"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc cc \
  --cxx c++ \
  --llvm-cmake-value OFF \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
-DCMAKE_C_COMPILER=cc
-DCMAKE_CXX_COMPILER=c++
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF
t_assert_eq "${_want}" "${_got}" "cross-nolinkflags: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "cross-nolinkflags: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── llvmdir-ignore ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "--llvm-dir + --llvm-ignore-paths emit LLVM_DIR then CMAKE_IGNORE_PATH"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value ON \
  --llvm-dir /opt/llvm/lib/cmake/llvm \
  --llvm-ignore-paths "/usr/lib;/usr/local/lib" \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DLLVM_DIR=/opt/llvm/lib/cmake/llvm
-DCMAKE_IGNORE_PATH=/usr/lib;/usr/local/lib
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=ON
EOF
t_assert_eq "${_want}" "${_got}" "llvmdir-ignore: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "llvmdir-ignore: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── llvmdir-ignore-ambient ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
export CMAKE_IGNORE_PATH="/ambient"
unset TVM_QNN_HOME
t_case "ambient CMAKE_IGNORE_PATH is appended with the ';' separator"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value ON \
  --llvm-dir /opt/llvm/lib/cmake/llvm \
  --llvm-ignore-paths /usr/lib \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DLLVM_DIR=/opt/llvm/lib/cmake/llvm
-DCMAKE_IGNORE_PATH=/usr/lib;/ambient
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=ON
EOF
t_assert_eq "${_want}" "${_got}" "llvmdir-ignore-ambient: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "llvmdir-ignore-ambient: TVM_QNN_HOME (non-local; tvm.sh stages from it)"
unset CMAKE_IGNORE_PATH

# ── llvmdir-only ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "empty --llvm-ignore-paths suppresses CMAKE_IGNORE_PATH entirely"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value ON \
  --llvm-dir /opt/llvm/lib/cmake/llvm \
  --llvm-ignore-paths "" \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DLLVM_DIR=/opt/llvm/lib/cmake/llvm
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=ON
EOF
t_assert_eq "${_want}" "${_got}" "llvmdir-only: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "llvmdir-only: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── cuda-opencl ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "--use-cuda 1 / --use-opencl 1 normalise to ON"
_emit \
  --out arr \
  --python-module ON \
  --build-type Debug \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value /usr/bin/llvm-config \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 \
  --use-cuda 1 \
  --use-opencl 1 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Debug
-DUSE_OPENCL=ON
-DUSE_CUDA=ON
-DTVM_BUILD_PYTHON_MODULE=ON
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=/usr/bin/llvm-config
EOF
t_assert_eq "${_want}" "${_got}" "cuda-opencl: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "cuda-opencl: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── qnn-on ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN="/opt/qairt/2.0"
unset TVM_QNN_HOME
t_case "resolve_qnn_sdk hit emits NO QNN cmake flags but still exports TVM_QNN_HOME"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value OFF \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 0 >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF
t_assert_eq "${_want}" "${_got}" "qnn-on: emitted CMake args drifted from the golden"
t_assert_eq "/opt/qairt/2.0" "${TVM_QNN_HOME:-}" "qnn-on: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── vulkan-lib-only ──
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME
t_case "Vulkan ON with only --vulkan-library emits just Vulkan_LIBRARY"
_emit \
  --out arr \
  --python-module OFF \
  --build-type Release \
  --cc /usr/bin/gcc \
  --cxx /usr/bin/g++ \
  --llvm-cmake-value OFF \
  --llvm-dir "" \
  --llvm-ignore-paths "" \
  --use-vulkan 1 \
  --use-cuda 0 \
  --use-opencl 0 \
  --spirv-tools-lib "" \
  --cross-link-flags "" \
  --vulkan-library /opt/vk/lib/libvulkan.so >/dev/null
read -r -d "" _want <<'EOF' || true
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
-DUSE_VULKAN=ON
-DVulkan_LIBRARY=/opt/vk/lib/libvulkan.so
-DUSE_LLVM=OFF
EOF
t_assert_eq "${_want}" "${_got}" "vulkan-lib-only: emitted CMake args drifted from the golden"
t_assert_eq "" "${TVM_QNN_HOME:-}" "vulkan-lib-only: TVM_QNN_HOME (non-local; tvm.sh stages from it)"

# ── argument validation: the whole point of the keyword interface ─────────────
STUB_CROSS=0; STUB_LAUNCHER=""; STUB_QNN=""
unset TVM_QNN_HOME

_common_args=( --out arr --python-module OFF --build-type Release
               --cc cc --cxx c++ --llvm-cmake-value OFF
               --llvm-dir "" --llvm-ignore-paths "" --use-vulkan 0 )

t_case "an unknown option is a HARD error, never silently ignored"
_out="$( (_emit "${_common_args[@]}" --use-vulcan 1) 2>&1 )" && _rc=0 || _rc=$?
t_assert_eq "97" "${_rc}" "a misspelled option must abort via die"
t_assert_contains "${_out}" "unknown option '--use-vulcan'"

t_case "a dropped required option is a HARD error"
_out="$( (_emit --out arr --python-module OFF --build-type Release \
                --cc cc --cxx c++ --llvm-cmake-value OFF \
                --llvm-dir "" --llvm-ignore-paths "") 2>&1 )" && _rc=0 || _rc=$?
t_assert_eq "97" "${_rc}" "missing --use-vulkan must abort via die"
t_assert_contains "${_out}" "missing required option '--use-vulkan'"

t_case "an option without a value is a HARD error (never eats the next flag)"
_out="$( (_emit "${_common_args[@]}" --vulkan-library) 2>&1 )" && _rc=0 || _rc=$?
t_assert_eq "97" "${_rc}" "a value-less trailing option must abort via die"
t_assert_contains "${_out}" "requires a value"

t_case "--out is validated before the nameref binding"
_out="$( (_emit --out "" --python-module OFF --build-type Release \
                --cc cc --cxx c++ --llvm-cmake-value OFF \
                --llvm-dir "" --llvm-ignore-paths "" --use-vulkan 0) 2>&1 )" && _rc=0 || _rc=$?
t_assert_eq "97" "${_rc}" "an empty --out must abort via die"

# Nameref collision: internals are _tvm_-prefixed now, so caller arrays named
# out_ref/llvm_dir work. docs/refactoring-backlog-archive-2026-08-31.md
t_case "a caller array named out_ref (or llvm_dir) no longer collides with the nameref"
_collide() {
  local -a out_ref=( -G Ninja )
  append_tvm_cmake_args --out out_ref --python-module OFF --build-type Release \
    --cc cc --cxx c++ --llvm-cmake-value OFF --llvm-dir "" \
    --llvm-ignore-paths "" --use-vulkan 0
  printf '%s\n' "${out_ref[@]}"
}
_out="$(_collide 2>&1)" && _rc=0 || _rc=$?
t_assert_eq "0" "${_rc}" "binding an array named out_ref must not be a circular reference"
t_assert_contains "${_out}" "-DUSE_LLVM=OFF"

# ── emit-block seams: each helper tested directly ────────────────────────────
# Not a subshell — _tvm_resolve_qnn_home sets a GLOBAL. $1.. is the helper call,
# whose first argument is always the array NAME "arr".
_direct() {
  local -a arr=()
  "$@"
  _got="$(printf '%s\n' "${arr[@]+${arr[@]}}")"
}

# _tvm_emit_cross_args
STUB_CROSS=0
t_case "_tvm_emit_cross_args emits nothing on a native build"
_direct _tvm_emit_cross_args arr "-L/ignored"
t_assert_eq "" "${_got}" "native must not emit cross/linker flags"

STUB_CROSS=1
unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS
t_case "_tvm_emit_cross_args: cross args, USE_ALTERNATIVE_LINKER, then EXE/SHARED/MODULE"
_direct _tvm_emit_cross_args arr "-L/t"
read -r -d "" _want <<'EOF' || true
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
-DCMAKE_EXE_LINKER_FLAGS=-L/t
-DCMAKE_SHARED_LINKER_FLAGS=-L/t
-DCMAKE_MODULE_LINKER_FLAGS=-L/t
EOF
t_assert_eq "${_want}" "${_got}" "cross emit block drifted"

t_case "_tvm_emit_cross_args with empty flags stops after USE_ALTERNATIVE_LINKER"
_direct _tvm_emit_cross_args arr ""
read -r -d "" _want <<'EOF' || true
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
EOF
t_assert_eq "${_want}" "${_got}" "cross emit block (no link flags) drifted"
STUB_CROSS=0

# _tvm_emit_llvm_args
t_case "_tvm_emit_llvm_args emits nothing without --llvm-dir"
_direct _tvm_emit_llvm_args arr "" "/usr/lib"
t_assert_eq "" "${_got}" "an ignore-path without an LLVM_DIR must emit nothing"

t_case "_tvm_emit_llvm_args emits LLVM_DIR then CMAKE_IGNORE_PATH"
_direct _tvm_emit_llvm_args arr /opt/llvm "/a;/b"
read -r -d "" _want <<'EOF' || true
-DLLVM_DIR=/opt/llvm
-DCMAKE_IGNORE_PATH=/a;/b
EOF
t_assert_eq "${_want}" "${_got}" "llvm emit block drifted"

# _tvm_emit_compiler_cache_args
STUB_LAUNCHER=""
t_case "_tvm_emit_compiler_cache_args emits nothing when there is no launcher"
_direct _tvm_emit_compiler_cache_args arr
t_assert_eq "" "${_got}" "no launcher must leave CMAKE_*_COMPILER_LAUNCHER unset"

STUB_LAUNCHER="/usr/bin/sccache"
t_case "_tvm_emit_compiler_cache_args emits C then CXX launcher"
_direct _tvm_emit_compiler_cache_args arr
read -r -d "" _want <<'EOF' || true
-DCMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache
-DCMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/sccache
EOF
t_assert_eq "${_want}" "${_got}" "compiler-cache emit block drifted"
STUB_LAUNCHER=""

# _tvm_emit_vulkan_args
t_case "_tvm_emit_vulkan_args 0 emits exactly USE_VULKAN=OFF"
_direct _tvm_emit_vulkan_args arr 0 /l /i /s
t_assert_eq "-DUSE_VULKAN=OFF" "${_got}" "Vulkan OFF must ignore the three paths"

t_case "_tvm_emit_vulkan_args 1 emits ON then LIBRARY, INCLUDE_DIR, SPIRV_TOOLS"
_direct _tvm_emit_vulkan_args arr 1 /l /i /s
read -r -d "" _want <<'EOF' || true
-DUSE_VULKAN=ON
-DVulkan_LIBRARY=/l
-DVulkan_INCLUDE_DIR=/i
-DVulkan_SPIRV_TOOLS_LIBRARY=/s
EOF
t_assert_eq "${_want}" "${_got}" "vulkan emit block drifted"

t_case "_tvm_emit_vulkan_args 1 with no paths emits only USE_VULKAN=ON"
_direct _tvm_emit_vulkan_args arr 1 "" "" ""
t_assert_eq "-DUSE_VULKAN=ON" "${_got}" "empty Vulkan paths must emit no Vulkan_* flags"

# _tvm_resolve_qnn_home
STUB_QNN="/opt/qairt/9.9"
unset TVM_QNN_HOME
t_case "_tvm_resolve_qnn_home sets the GLOBAL and emits no cmake args"
_direct _tvm_resolve_qnn_home
t_assert_eq "" "${_got}" "the QNN seam must not emit any -D flag"
t_assert_eq "/opt/qairt/9.9" "${TVM_QNN_HOME:-}" "TVM_QNN_HOME must survive as a global"

TVM_QNN_HOME="/preset"
t_case "_tvm_resolve_qnn_home does not override a preset TVM_QNN_HOME"
_direct _tvm_resolve_qnn_home
t_assert_eq "/preset" "${TVM_QNN_HOME:-}" "a preset TVM_QNN_HOME wins over resolve_qnn_sdk"
STUB_QNN=""; unset TVM_QNN_HOME

# The seams add namerefs, so the REAL call-site array names must still bind.
t_case "the real call-site array names (cmake_args, wheel_cmake_args) still bind"
_callsite_names() {
  local -a cmake_args=() wheel_cmake_args=()
  append_tvm_cmake_args --out cmake_args --python-module OFF --build-type Release \
    --cc cc --cxx c++ --llvm-cmake-value OFF --llvm-dir /d --llvm-ignore-paths /i \
    --use-vulkan 1 --vulkan-library /l
  append_tvm_cmake_args --out wheel_cmake_args --python-module ON --build-type Release \
    --cc cc --cxx c++ --llvm-cmake-value OFF --llvm-dir "" --llvm-ignore-paths "" \
    --use-vulkan 0
  printf '%s|%s\n' "${cmake_args[*]}" "${wheel_cmake_args[*]}"
}
STUB_CROSS=1; STUB_LAUNCHER="/l/sccache"
_out="$(_callsite_names 2>&1)" && _rc=0 || _rc=$?
STUB_CROSS=0; STUB_LAUNCHER=""
t_assert_eq "0" "${_rc}" "binding cmake_args/wheel_cmake_args must not be a circular reference"
t_assert_eq "-DCMAKE_BUILD_TYPE=Release -DUSE_OPENCL=OFF -DUSE_CUDA=OFF -DTVM_BUILD_PYTHON_MODULE=OFF -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DUSE_ALTERNATIVE_LINKER=OFF -DLLVM_DIR=/d -DCMAKE_IGNORE_PATH=/i -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ -DCMAKE_C_COMPILER_LAUNCHER=/l/sccache -DCMAKE_CXX_COMPILER_LAUNCHER=/l/sccache -DUSE_VULKAN=ON -DVulkan_LIBRARY=/l -DUSE_LLVM=OFF|-DCMAKE_BUILD_TYPE=Release -DUSE_OPENCL=OFF -DUSE_CUDA=OFF -DTVM_BUILD_PYTHON_MODULE=ON -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DUSE_ALTERNATIVE_LINKER=OFF -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ -DCMAKE_C_COMPILER_LAUNCHER=/l/sccache -DCMAKE_CXX_COMPILER_LAUNCHER=/l/sccache -DUSE_VULKAN=OFF -DUSE_LLVM=OFF" \
  "${_out}" "call-site array names: emitted args drifted"

t_summary
