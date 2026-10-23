#!/usr/bin/env bash
# Golden fixtures cover argument order and globals, not CMake configuration or TVM builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../05-frameworks/tvm-config.sh
source "${TESTS_DIR}/../05-frameworks/tvm-config.sh"

# Stubbed collaborators
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

# Not a subshell: TVM_QNN_HOME is set non-locally and would be swallowed.
_got=""
_emit() {
  local -a arr=( -G Ninja )
  append_tvm_cmake_args "$@"
  _got="$(printf '%s\n' "${arr[@]}")"
  printf '%s\n' "${_got}"
}

golden_release_cpu="$(cat <<'EOF'
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=OFF
EOF
)"
golden_native_compilers="$(cat <<'EOF'
-DCMAKE_C_COMPILER=/usr/bin/gcc
-DCMAKE_CXX_COMPILER=/usr/bin/g++
EOF
)"
golden_cross_compilers="$(cat <<'EOF'
-DCMAKE_C_COMPILER=/usr/bin/aarch64-linux-gnu-gcc
-DCMAKE_CXX_COMPILER=/usr/bin/aarch64-linux-gnu-g++
EOF
)"
golden_cross_system="$(cat <<'EOF'
-DCMAKE_SYSTEM_NAME=Linux
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DUSE_ALTERNATIVE_LINKER=OFF
EOF
)"
golden_cache_launchers="$(cat <<'EOF'
-DCMAKE_C_COMPILER_LAUNCHER=/usr/bin/sccache
-DCMAKE_CXX_COMPILER_LAUNCHER=/usr/bin/sccache
EOF
)"

golden_vulkan_loader="$(cat <<'EOF'
-DUSE_VULKAN=ON
-DVulkan_LIBRARY=/opt/vk/lib/libvulkan.so
EOF
)"

_reset_fixture() {
  STUB_CROSS="$1"
  STUB_LAUNCHER="$2"
  STUB_QNN="$3"
  unset TVM_QNN_HOME
}

_emit_fixture() {
  local python_module="$1" build_type="$2" cc="$3" cxx="$4"
  local llvm="$5" llvm_dir="$6" ignore="$7" vulkan="$8"
  shift 8
  _emit --out arr --python-module "$python_module" --build-type "$build_type" \
    --cc "$cc" --cxx "$cxx" --llvm-cmake-value "$llvm" --llvm-dir "$llvm_dir" \
    --llvm-ignore-paths "$ignore" --use-vulkan "$vulkan" "$@" >/dev/null
}

_golden_case() {
  local name="$1" qnn_home="$2" expected
  shift 2
  expected="$(cat)"
  _emit_fixture "$@"
  t_assert_eq "$expected" "${_got}" "$name: emitted CMake args drifted from the golden"
  t_assert_eq "$qnn_home" "${TVM_QNN_HOME:-}" "$name: TVM_QNN_HOME (non-local; tvm.sh stages from it)"
}

_native_golden_case() {
  local name="$1" qnn="$2" python_module="$3" build_type="$4" llvm="$5" vulkan="$6"
  shift 6
  _golden_case "$name" "$qnn" "$python_module" "$build_type" /usr/bin/gcc /usr/bin/g++ "$llvm" '' '' "$vulkan" "$@"
}

# native-vulkan-off
_reset_fixture 0 "" ""
t_case "native build, Vulkan OFF, no LLVM_DIR, no launcher, no QNN"
_native_golden_case native-vulkan-off '' OFF Release /usr/bin/llvm-config 0 <<EOF
${golden_release_cpu}
${golden_native_compilers}
-DUSE_VULKAN=OFF
-DUSE_LLVM=/usr/bin/llvm-config
EOF

# native-vulkan-on
_reset_fixture 0 "/usr/bin/sccache" ""
t_case "Vulkan ON emits all three Vulkan_* flags in LIBRARY, INCLUDE_DIR, SPIRV_TOOLS order"
_native_golden_case native-vulkan-on '' ON Release /usr/bin/llvm-config 1 \
  --use-cuda 0 --use-opencl 0 --spirv-tools-lib /opt/vulkan/lib/libSPIRV-Tools.a --cross-link-flags '' --vulkan-library /opt/vk/lib/libvulkan.so --vulkan-include /opt/vk/include <<EOF
-G
Ninja
-DCMAKE_BUILD_TYPE=Release
-DUSE_OPENCL=OFF
-DUSE_CUDA=OFF
-DTVM_BUILD_PYTHON_MODULE=ON
${golden_native_compilers}
${golden_cache_launchers}
${golden_vulkan_loader}
-DVulkan_INCLUDE_DIR=/opt/vk/include
-DVulkan_SPIRV_TOOLS_LIBRARY=/opt/vulkan/lib/libSPIRV-Tools.a
-DUSE_LLVM=/usr/bin/llvm-config
EOF

_cross_golden_case() {
  local name="$1" description="$2" search_flags="$3" linker_expected
  shift 3
  linker_expected="$(cat)"
  _reset_fixture 1 "" ""
  t_case "$description"
  _golden_case "$name" '' OFF Release /usr/bin/aarch64-linux-gnu-gcc /usr/bin/aarch64-linux-gnu-g++ OFF '' '' 0 \
    "$@" --cross-link-flags "$search_flags" <<EOF
${golden_release_cpu}
${golden_cross_system}
${linker_expected}
${golden_cross_compilers}
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF
}

_cross_golden_case cross-linkflags "cross build: cross args, USE_ALTERNATIVE_LINKER=OFF, three *_LINKER_FLAGS" \
  '-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu' --use-cuda 0 --use-opencl 0 --spirv-tools-lib '' <<EOF
-DCMAKE_EXE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
-DCMAKE_SHARED_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
-DCMAKE_MODULE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -L/lib/aarch64-linux-gnu
EOF
export CMAKE_EXE_LINKER_FLAGS="-Wl,-exe" CMAKE_SHARED_LINKER_FLAGS="-Wl,-shared" CMAKE_MODULE_LINKER_FLAGS="-Wl,-module"
_cross_golden_case cross-linkflags-ambient "ambient CMAKE_*_LINKER_FLAGS are appended after the cross search flags" \
  -L/usr/lib/aarch64-linux-gnu <<EOF
-DCMAKE_EXE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-exe
-DCMAKE_SHARED_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-shared
-DCMAKE_MODULE_LINKER_FLAGS=-L/usr/lib/aarch64-linux-gnu -Wl,-module
EOF
unset CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS

# cross-nolinkflags
_reset_fixture 1 "" ""
t_case "cross build with empty --cross-link-flags emits NO *_LINKER_FLAGS"
_golden_case cross-nolinkflags '' OFF Release cc c++ OFF '' '' 0 <<EOF
${golden_release_cpu}
${golden_cross_system}
-DCMAKE_C_COMPILER=cc
-DCMAKE_CXX_COMPILER=c++
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF

_llvm_golden_case() {
  local name="$1" description="$2" ignore="$3" expected_ignore="$4"
  _reset_fixture 0 "" ""
  t_case "$description"
  _golden_case "$name" '' OFF Release /usr/bin/gcc /usr/bin/g++ ON /opt/llvm/lib/cmake/llvm "$ignore" 0 <<EOF
${golden_release_cpu}
-DLLVM_DIR=/opt/llvm/lib/cmake/llvm
${expected_ignore:+${expected_ignore}
}${golden_native_compilers}
-DUSE_VULKAN=OFF
-DUSE_LLVM=ON
EOF
}

_llvm_golden_case llvmdir-ignore "--llvm-dir + --llvm-ignore-paths emit LLVM_DIR then CMAKE_IGNORE_PATH" \
  '/usr/lib;/usr/local/lib' '-DCMAKE_IGNORE_PATH=/usr/lib;/usr/local/lib'
export CMAKE_IGNORE_PATH="/ambient"
_llvm_golden_case llvmdir-ignore-ambient "ambient CMAKE_IGNORE_PATH is appended with the ';' separator" \
  /usr/lib '-DCMAKE_IGNORE_PATH=/usr/lib;/ambient'
unset CMAKE_IGNORE_PATH
_llvm_golden_case llvmdir-only "empty --llvm-ignore-paths suppresses CMAKE_IGNORE_PATH entirely" '' ''

# cuda-opencl
_reset_fixture 0 "" ""
t_case "--use-cuda 1 / --use-opencl 1 normalise to ON"
_native_golden_case cuda-opencl '' ON Debug /usr/bin/llvm-config 0 \
  --use-cuda 1 --use-opencl 1 <<EOF
-G
Ninja
-DCMAKE_BUILD_TYPE=Debug
-DUSE_OPENCL=ON
-DUSE_CUDA=ON
-DTVM_BUILD_PYTHON_MODULE=ON
-DUSE_CUDNN=ON
-DUSE_CUBLAS=ON
${golden_native_compilers}
-DUSE_VULKAN=OFF
-DUSE_LLVM=/usr/bin/llvm-config
EOF

_emit_cuda_fixture() {
  _emit_fixture ON Debug /usr/bin/gcc /usr/bin/g++ /usr/bin/llvm-config '' '' 0 --use-cuda "$1" --use-opencl 0
}

# CUDA companions: USE_CUDA alone leaves conv/gemm on generated kernels; cuDNN without CUDA fails configure
t_case "the CUDA companions are ON by default, and only when CUDA is"
_emit_cuda_fixture 1
t_assert_contains "${_got}" "-DUSE_CUDNN=ON"  "cuDNN must default ON alongside CUDA"
t_assert_contains "${_got}" "-DUSE_CUBLAS=ON" "cuBLAS must default ON alongside CUDA"

t_case "CUDA OFF emits NO companion flags at all"
_emit_cuda_fixture 0
t_assert_eq "0" "$(printf '%s' "${_got}" | grep -c -- '-DUSE_CUDNN' || true)" \
  "cuDNN must not be requested without CUDA"
t_assert_eq "0" "$(printf '%s' "${_got}" | grep -c -- '-DUSE_CUBLAS' || true)" \
  "cuBLAS must not be requested without CUDA"

_assert_companion_opt_out() {
  local disabled="$1" retained="$2" disabled_reason="$3" retained_reason="$4"
  _emit_cuda_fixture 1
  t_assert_contains "${_got}" "-DUSE_${disabled}=OFF" "$disabled_reason"
  t_assert_contains "${_got}" "-DUSE_${retained}=ON" "$retained_reason"
}

t_case "each companion has its own opt-out knob"
TVM_USE_CUDNN=0 _assert_companion_opt_out CUDNN CUBLAS \
  "TVM_USE_CUDNN=0 must turn cuDNN off" "and must NOT drag cuBLAS off with it"
TVM_USE_CUBLAS=0 _assert_companion_opt_out CUBLAS CUDNN \
  "TVM_USE_CUBLAS=0 must turn cuBLAS off" "and must NOT drag cuDNN off with it"

# qnn-on
_reset_fixture 0 "" "/opt/qairt/2.0"
t_case "resolve_qnn_sdk hit emits NO QNN cmake flags but still exports TVM_QNN_HOME"
_native_golden_case qnn-on /opt/qairt/2.0 OFF Release OFF 0 <<EOF
${golden_release_cpu}
${golden_native_compilers}
-DUSE_VULKAN=OFF
-DUSE_LLVM=OFF
EOF

# vulkan-lib-only
_reset_fixture 0 "" ""
t_case "Vulkan ON with only --vulkan-library emits just Vulkan_LIBRARY"
_native_golden_case vulkan-lib-only '' OFF Release OFF 1 \
  --use-cuda 0 --use-opencl 0 --spirv-tools-lib '' --cross-link-flags '' --vulkan-library /opt/vk/lib/libvulkan.so <<EOF
${golden_release_cpu}
${golden_native_compilers}
${golden_vulkan_loader}
-DUSE_LLVM=OFF
EOF

# Argument validation, the point of the keyword interface
_reset_fixture 0 "" ""

_common_args=( --out arr --python-module OFF --build-type Release
               --cc cc --cxx c++ --llvm-cmake-value OFF
               --llvm-dir "" --llvm-ignore-paths "" --use-vulkan 0 )

_assert_invalid_args() {
  local description="$1" reason="$2" diagnostic="$3" output rc
  shift 3
  t_case "$description"
  output="$( (_emit "$@") 2>&1 )" && rc=0 || rc=$?
  t_assert_eq "97" "$rc" "$reason"
  if [ -n "$diagnostic" ]; then t_assert_contains "$output" "$diagnostic"; fi
}

_assert_invalid_args "an unknown option is a HARD error, never silently ignored" \
  "a misspelled option must abort via die" "unknown option '--use-vulcan'" "${_common_args[@]}" --use-vulcan 1
_assert_invalid_args "a dropped required option is a HARD error" \
  "missing --use-vulkan must abort via die" "missing required option '--use-vulkan'" "${_common_args[@]:0:${#_common_args[@]}-2}"
_assert_invalid_args "an option without a value is a HARD error (never eats the next flag)" \
  "a value-less trailing option must abort via die" 'requires a value' "${_common_args[@]}" --vulkan-library
_assert_invalid_args "--out is validated before the nameref binding" \
  "an empty --out must abort via die" '' --out "" "${_common_args[@]:2}"

# Internals are _tvm_-prefixed so a caller array's name cannot collide with the nameref.
t_case "a caller array named out_ref (or llvm_dir) no longer collides with the nameref"
_collide() {
  local -a out_ref=( -G Ninja )
  append_tvm_cmake_args --out out_ref "${_common_args[@]:2}"
  printf '%s\n' "${out_ref[@]}"
}
_out="$(_collide 2>&1)" && _rc=0 || _rc=$?
t_assert_eq "0" "${_rc}" "binding an array named out_ref must not be a circular reference"
t_assert_contains "${_out}" "-DUSE_LLVM=OFF"

# Emit-block helpers, directly; not a subshell, since _tvm_resolve_qnn_home sets a global
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
read -r -d "" _want <<EOF || true
${golden_cross_system}
-DCMAKE_EXE_LINKER_FLAGS=-L/t
-DCMAKE_SHARED_LINKER_FLAGS=-L/t
-DCMAKE_MODULE_LINKER_FLAGS=-L/t
EOF
t_assert_eq "${_want}" "${_got}" "cross emit block drifted"

t_case "_tvm_emit_cross_args with empty flags stops after USE_ALTERNATIVE_LINKER"
_direct _tvm_emit_cross_args arr ""
read -r -d "" _want <<EOF || true
${golden_cross_system}
EOF
t_assert_eq "${_want}" "${_got}" "cross emit block (no link flags) drifted"
STUB_CROSS=0

# _tvm_emit_llvm_args
t_case "_tvm_emit_llvm_args emits nothing without --llvm-dir"
_direct _tvm_emit_llvm_args arr "" "/usr/lib"
t_assert_eq "" "${_got}" "an ignore-path without an LLVM_DIR must emit nothing"

t_case "_tvm_emit_llvm_args emits LLVM_DIR then CMAKE_IGNORE_PATH"
_direct _tvm_emit_llvm_args arr /opt/llvm "/a;/b"
read -r -d "" _want <<EOF || true
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
read -r -d "" _want <<EOF || true
${golden_cache_launchers}
EOF
t_assert_eq "${_want}" "${_got}" "compiler-cache emit block drifted"
STUB_LAUNCHER=""

# _tvm_emit_vulkan_args
t_case "_tvm_emit_vulkan_args 0 emits exactly USE_VULKAN=OFF"
_direct _tvm_emit_vulkan_args arr 0 /l /i /s
t_assert_eq "-DUSE_VULKAN=OFF" "${_got}" "Vulkan OFF must ignore the three paths"

t_case "_tvm_emit_vulkan_args 1 emits ON then LIBRARY, INCLUDE_DIR, SPIRV_TOOLS"
_direct _tvm_emit_vulkan_args arr 1 /l /i /s
read -r -d "" _want <<EOF || true
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
  append_tvm_cmake_args --out wheel_cmake_args --python-module ON "${_common_args[@]:4}"
  printf '%s|%s\n' "${cmake_args[*]}" "${wheel_cmake_args[*]}"
}
STUB_CROSS=1; STUB_LAUNCHER="/l/sccache"
_out="$(_callsite_names 2>&1)" && _rc=0 || _rc=$?
STUB_CROSS=0; STUB_LAUNCHER=""
t_assert_eq "0" "${_rc}" "binding cmake_args/wheel_cmake_args must not be a circular reference"
t_assert_eq "-DCMAKE_BUILD_TYPE=Release -DUSE_OPENCL=OFF -DUSE_CUDA=OFF -DTVM_BUILD_PYTHON_MODULE=OFF -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DUSE_ALTERNATIVE_LINKER=OFF -DLLVM_DIR=/d -DCMAKE_IGNORE_PATH=/i -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ -DCMAKE_C_COMPILER_LAUNCHER=/l/sccache -DCMAKE_CXX_COMPILER_LAUNCHER=/l/sccache -DUSE_VULKAN=ON -DVulkan_LIBRARY=/l -DUSE_LLVM=OFF|-DCMAKE_BUILD_TYPE=Release -DUSE_OPENCL=OFF -DUSE_CUDA=OFF -DTVM_BUILD_PYTHON_MODULE=ON -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DUSE_ALTERNATIVE_LINKER=OFF -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ -DCMAKE_C_COMPILER_LAUNCHER=/l/sccache -DCMAKE_CXX_COMPILER_LAUNCHER=/l/sccache -DUSE_VULKAN=OFF -DUSE_LLVM=OFF" \
  "${_out}" "call-site array names: emitted args drifted"

t_case "native and wheel argument forwarding preserves every resolved value"
eval "$(t_fn_src "${TESTS_DIR}/../05-frameworks/tvm.sh" append_tvm_resolved_cmake_args)"
_resolved_args() {
  (
    append_tvm_cmake_args() { printf '<%s>' "$@"; }
    build_type='Debug mode' desired_cc='cc path' desired_cxx='cxx path' \
      llvm_cmake_value=llvm-config llvm_dir='/llvm dir' llvm_ignore_paths='/foreign;/other' \
      use_vulkan=1 use_cuda=0 use_opencl=1 spirv_tools_lib='/spirv path' \
      cross_link_flags='-L/target -Wl,flags' vulkan_library='/vulkan lib' vulkan_include='/vulkan include' \
      append_tvm_resolved_cmake_args "$1" "$2"
  )
}
_resolved_expected='<--out><cmake_args><--python-module><OFF><--build-type><Debug mode><--cc><cc path><--cxx><cxx path><--llvm-cmake-value><llvm-config><--llvm-dir></llvm dir><--llvm-ignore-paths></foreign;/other><--use-vulkan><1><--use-cuda><0><--use-opencl><1><--spirv-tools-lib></spirv path><--cross-link-flags><-L/target -Wl,flags><--vulkan-library></vulkan lib><--vulkan-include></vulkan include>'
t_assert_eq "${_resolved_expected}" "$(_resolved_args cmake_args OFF)"
t_assert_eq "${_resolved_expected/<cmake_args><--python-module><OFF>/<wheel_cmake_args><--python-module><ON>}" "$(_resolved_args wheel_cmake_args ON)"
for _site in 'tvm.sh cmake_args OFF' 'tvm-python.sh wheel_cmake_args ON'; do
  read -r _file _array _module <<< "${_site}"
  t_assert_contains "$(cat "${TESTS_DIR}/../05-frameworks/${_file}")" "append_tvm_resolved_cmake_args ${_array} ${_module}"
done

t_summary
