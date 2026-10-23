#!/usr/bin/env bash
# Extracted ORT helpers cover exact cross argv and advisory library staging, not compiler execution or ABI compatibility.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
repo="${1:-${_T_SCRIPTS}/../..}"
common="$repo/linux/scripts/03-media/build/onnxruntime/build/lib/common.sh"
source "$repo/linux/scripts/01-core/elf-strip.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for helper in append_onnx_cross_cmake_build_args copy_onnx_libraries_to_output append_onnx_cross_toolchain_args apply_onnx_library_action; do
  if grep -q "^${helper}()" "$common"; then eval "$(t_fn_src "$common" "$helper")"; fi
done
python3 - "$repo" "$work/genai.sh" <<'PY'
from pathlib import Path
import sys
text=(Path(sys.argv[1])/'linux/scripts/03-media/build/onnxruntime/build/60-build-genai.sh').read_text()
a=text.index('_GENAI_MODULE_EXT=""')
b=text.index('\nfi',a)+3
cross=text[a:b]
a=text.index('GENAI_LIB_DIR=')
b=text.index('\n# GenAI inherits',a)
native=(Path(sys.argv[1])/'linux/scripts/03-media/build/onnxruntime/build/30-build-native.sh').read_text()
native_start=native.index('if [ "${MEDIA_STRIP:-1}"')
native_end=native.index('\nfi',native_start)+3
Path(sys.argv[2]).write_text('genai_cross() {\n'+cross+'\n}\ngenai_stage() {\n'+text[a:b]+'\n}\nnative_strip() {\n'+native[native_start:native_end]+'\n}\n')
PY
source "$work/genai.sh"
export CROSS_TARGET_TRIPLET GENAI_CROSS_BUILD GENAI_CONFIG STRIP MEDIA_STRIP GENAI_SRC_DIR
CROSS_TARGET_PROCESSOR='target processor'; CC='/compiler path/cc'; CXX='/compiler path/cxx'
CROSS_TARGET_TRIPLET=fixture-linux-gnu; CROSS_RUST_TARGET=fixture-rust; HOST_PYTHON='/host python'
info() { :; }
err() { printf '%s\n' "$*" >&2; return 7; }
cross_target_python_dev_ready() { if [ "$ready" = yes ]; then return 0; else return 1; fi; }
cross_target_arch() { printf '%s' "$arch"; }
cross_target_python_include_dir() { printf '/target include'; }
host_python_major_minor() { printf 3.99; }
cross_wheel_platform_tag() { printf linux_fixture; }
core=(--cmake_extra_defines CMAKE_SYSTEM_NAME=Linux "CMAKE_SYSTEM_PROCESSOR=$CROSS_TARGET_PROCESSOR" "CMAKE_C_COMPILER=$CC" "CMAKE_CXX_COMPILER=$CXX" "CMAKE_ASM_COMPILER=$CC" CMAKE_SYSROOT=/ CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY)
for ready in yes no; do
  for arch in amd64 riscv64; do
    t_case "Runtime $arch Python $ready retains exact argv and nameref mutation"
    args=('initial arg'); expected=('initial arg' "${core[@]}")
    enabled=OFF; [ "$ready" != yes ] || enabled=ON
    expected+=("onnxruntime_ENABLE_PYTHON=$enabled" onnxruntime_BUILD_UNIT_TESTS=OFF onnxruntime_GENERATE_TEST_REPORTS=OFF)
    [ "$arch" != riscv64 ] || expected+=(--cmake_extra_defines onnxruntime_USE_RVV=ON)
    append_onnx_cross_cmake_build_args args
    t_assert_eq "$(printf '<%s>\n' "${expected[@]}")" "$(printf '<%s>\n' "${args[@]}")"
  done
done
t_case 'GenAI cross options preserve suffix, wheel platform, and caller options after toolchain args'
GENAI_CROSS_BUILD=true; GENAI_BASE_ARGS=('initial arg')
genai_cross
expected=('initial arg' "${core[@]}" ENABLE_TESTS=OFF ENABLE_MODEL_BENCHMARK=OFF "Rust_CARGO_TARGET=$CROSS_RUST_TARGET" "Python_EXECUTABLE=$HOST_PYTHON" "PYTHON_EXECUTABLE=$HOST_PYTHON" 'PYTHON_INCLUDE_DIR=/target include' PYBIND11_PYTHONLIBS_OVERWRITE=OFF 'PYTHON_MODULE_EXTENSION=.cpython-399-fixture-linux-gnu.so')
t_assert_eq "$(printf '<%s>\n' "${expected[@]}")" "$(printf '<%s>\n' "${GENAI_BASE_ARGS[@]}")"
t_assert_eq .cpython-399-fixture-linux-gnu.so "$_GENAI_MODULE_EXT"
t_assert_eq linux_fixture "$_PYTHON_HOST_PLATFORM"
t_case 'native GenAI leaves argument vector and target platform untouched'
GENAI_CROSS_BUILD=false; GENAI_BASE_ARGS=('native arg'); _PYTHON_HOST_PLATFORM=keep
genai_cross
t_assert_eq 'native arg' "${GENAI_BASE_ARGS[*]}"
t_assert_eq '' "$_GENAI_MODULE_EXT"
t_assert_eq keep "$_PYTHON_HOST_PLATFORM"
for policy in runtime genai; do
  t_case "$policy copies only selected regular top-level libraries, including paths with spaces"
  source_dir="$work/source $policy"; output="$work/output $policy"
  mkdir -p "$source_dir/Release/nested" "$output/lib"
  for name in libonnxruntime.so.1 libonnxruntime_providers_cpu.so libonnxruntime-genai.so.2 foreign.so foreign.so.3 archive.a; do printf '%s' "$name" > "$source_dir/Release/$name"; done
  printf nested > "$source_dir/Release/nested/libonnxruntime.so"
  ln -s libonnxruntime.so.1 "$source_dir/Release/libonnxruntime-link.so"
  if [ "$policy" = runtime ]; then
    copy_onnx_libraries_to_output "$source_dir" Release "$output"
    names=$'libonnxruntime-genai.so.2\nlibonnxruntime.so.1\nlibonnxruntime_providers_cpu.so'
  else
    GENAI_SRC_DIR="$source_dir"; GENAI_CONFIG=Release; GENAI_OUTPUT_DIR="$output"
    mkdir -p "$source_dir/build/Linux"; mv "$source_dir/Release" "$source_dir/build/Linux/Release"
    genai_stage
    names=$'foreign.so\nlibonnxruntime-genai.so.2\nlibonnxruntime_providers_cpu.so'
  fi
  actual="$(printf '%s\n' "$output/lib/"* | sed "s|$output/lib/||" | LC_ALL=C sort)"
  t_assert_eq "$names" "$actual"
  for file in "$output/lib/"*; do t_assert_eq "$(basename "$file")" "$(cat "$file")"; done
  t_case "$policy missing input is advisory and preserves output-directory policy"
  if [ "$policy" = runtime ]; then
    t_assert_eq 0 "$(t_rc copy_onnx_libraries_to_output "$work/missing" Release "$work/empty runtime")"
    t_assert_eq true "$([ -d "$work/empty runtime/lib" ] && echo true)"
  else
    GENAI_SRC_DIR="$work/missing"; GENAI_OUTPUT_DIR="$work/empty genai"
    t_assert_eq 0 "$(t_rc genai_stage)"
    t_assert_eq false "$([ -e "$GENAI_OUTPUT_DIR" ] && echo true || echo false)"
  fi
done
t_case 'native strip retains depth2, regular-file selection, flag order, and advisory command failure'
NATIVE_CPU_OUTPUT_DIR="$work/native strip"
mkdir -p "$NATIVE_CPU_OUTPUT_DIR/lib/nested/deep" "$work/bin"
for path in lib/a.so lib/b.so.1 lib/nested/c.so lib/nested/deep/ignored.so lib/archive.a; do printf payload > "$NATIVE_CPU_OUTPUT_DIR/$path"; done
ln -s a.so "$NATIVE_CPU_OUTPUT_DIR/lib/linked.so"
ln -s missing "$NATIVE_CPU_OUTPUT_DIR/lib/dangling.so"
cat > "$work/bin/strip" <<'BASH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STRIP_FLAGS"
shift
printf '%s\n' "$@" >> "$STRIP_FILES"
exit 5
BASH
chmod +x "$work/bin/strip"
export STRIP_FLAGS="$work/strip.flags" STRIP_FILES="$work/strip.files"
STRIP="$work/bin/strip"
t_assert_eq 0 "$(t_rc native_strip)"
t_assert_eq --strip-all "$(cat "$STRIP_FLAGS")"
t_assert_eq "$(printf '%s\n' "$NATIVE_CPU_OUTPUT_DIR/lib/a.so" "$NATIVE_CPU_OUTPUT_DIR/lib/b.so.1" "$NATIVE_CPU_OUTPUT_DIR/lib/nested/c.so")" "$(LC_ALL=C sort "$STRIP_FILES")"
rm "$STRIP_FLAGS" "$STRIP_FILES"
MEDIA_STRIP=0
t_assert_eq 0 "$(t_rc native_strip)"
t_assert_eq false "$([ -e "$STRIP_FLAGS" ] && echo true || echo false)"
MEDIA_STRIP=1
unset STRIP
PATH="$work/bin:$PATH" native_strip
t_assert_eq --strip-all "$(cat "$STRIP_FLAGS")"
t_case 'copy command failures remain advisory for both Runtime and GenAI'
cat > "$work/bin/cp" <<'BASH'
#!/usr/bin/env bash
printf attempted >> "$COPY_ATTEMPTS"
exit 6
BASH
chmod +x "$work/bin/cp"
export COPY_ATTEMPTS="$work/copy.attempts"
PATH="$work/bin:$PATH"
t_assert_eq 0 "$(t_rc copy_onnx_libraries_to_output "$work/source runtime" Release "$work/copy failure")"
GENAI_SRC_DIR="$work/source genai"; GENAI_OUTPUT_DIR="$work/copy failure"
t_assert_eq 0 "$(t_rc genai_stage)"
t_assert_eq attemptedattempted "$(cat "$COPY_ATTEMPTS")"
t_case 'find failures remain advisory for copy and strip in direct and conditional contexts'
find() { return 8; }
t_assert_eq 0 "$(t_rc copy_onnx_libraries_to_output "$work/source runtime" Release "$work/find failure")"
t_assert_eq 0 "$(t_rc genai_stage)"
t_assert_eq 0 "$(t_rc native_strip)"
if native_strip; then actual=accepted; else actual=rejected; fi
t_assert_eq accepted "$actual"
unset -f find
t_case 'shared-prefix strip keeps arbitrary glob list, depth1 and disabled/missing no-ops'
t_source_functions "$repo/linux/scripts/01-core/build-helpers.sh" strip_media_libs
source "$repo/linux/scripts/01-core/elf-strip.sh"
_resolve_media_strip_bin() { printf '%s' "$work/bin/strip"; }
MEDIA_STRIP=1
rm "$STRIP_FLAGS" "$STRIP_FILES"
strip_media_libs "$NATIVE_CPU_OUTPUT_DIR/lib" a.so b.so.1 '*.absent'
t_assert_eq "$(printf '%s\n' "$NATIVE_CPU_OUTPUT_DIR/lib/a.so" "$NATIVE_CPU_OUTPUT_DIR/lib/b.so.1")" "$(LC_ALL=C sort "$STRIP_FILES")"
rm "$STRIP_FLAGS" "$STRIP_FILES"
strip_media_libs "$NATIVE_CPU_OUTPUT_DIR/lib"
strip_media_libs "$work/absent" '*.so'
MEDIA_STRIP=0
strip_media_libs "$NATIVE_CPU_OUTPUT_DIR/lib" '*.so'
t_assert_eq false "$([ -e "$STRIP_FILES" ] && echo true || echo false)"
t_case 'wheel repair strips recursively, repacks after advisory strip failure and preserves pure Python wheel'
t_source_functions "$repo/linux/scripts/03-media/runtime/repair-wheels.sh" strip_cross_wheels
WHEELS_DIR="$work/repair wheels"
mkdir -p "$WHEELS_DIR"
printf pure > "$WHEELS_DIR/pure-none-any.whl"
printf original > "$WHEELS_DIR/native.whl"
first_match() { find "$@" | head -1; }
uv() {
  if [ "$5" = unpack ]; then
    mkdir -p "$8/pkg/nested/deep"
    printf payload > "$8/pkg/nested/deep/module.so.1"
    printf payload > "$8/pkg/module.so"
    printf text > "$8/pkg/archive.a"
    ln -s module.so "$8/pkg/link.so"
  else
    printf repacked > "$8/native.whl"
  fi
}
MEDIA_STRIP=1
strip_cross_wheels > "$work/repair.out"
t_assert_eq pure "$(cat "$WHEELS_DIR/pure-none-any.whl")"
t_assert_eq repacked "$(cat "$WHEELS_DIR/native.whl")"
t_assert_eq --strip-all "$(cat "$STRIP_FLAGS")"
t_assert_eq 2 "$(wc -l < "$STRIP_FILES" | tr -d ' ')"
t_assert_eq 'module.so' "$(basename "$(head -1 "$STRIP_FILES")")"
t_assert_eq 'module.so.1' "$(basename "$(tail -1 "$STRIP_FILES")")"
t_summary
