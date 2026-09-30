#!/usr/bin/env bash
# A native TVM links /usr/local/llvm-target's CMake package, never apt's llvm-config; see docs/cross-build-verification.md#the-linuxscriptstests-suites
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=../05-frameworks/tvm-detect.sh
source "${TESTS_DIR}/../05-frameworks/tvm-detect.sh"
log() { :; }
die() { printf 'DIE:%s\n' "$*" >&2; exit 97; }

root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT
_pkg() { mkdir -p "$1"; : > "$1/LLVMConfig.cmake"; }
_canon() { readlink -f "$1"; }
_pkg "${root}/shipped/lib/cmake/llvm"
_pkg "${root}/lib64-only/lib64/cmake/llvm"
_pkg "${root}/target/lib/cmake/llvm"
mkdir -p "${root}/empty"

t_case "the native package is the shipped tree's lib/cmake/llvm"
t_assert_eq "$(_canon "${root}/shipped/lib/cmake/llvm")" "$(detect_native_llvm_cmake_dir "${root}/shipped")"
t_case "a lib64 tree is found too"
t_assert_eq "$(_canon "${root}/lib64-only/lib64/cmake/llvm")" "$(detect_native_llvm_cmake_dir "${root}/lib64-only")"
t_case "no package, no answer: the caller falls back to llvm-config"
t_assert_eq "" "$(detect_native_llvm_cmake_dir "${root}/empty")"

# resolve_tvm_llvm is a main() phase helper: lifted out, run over main()'s locals.
_src="$(t_fn_src "${TESTS_DIR}/../05-frameworks/tvm.sh" resolve_tvm_llvm)" || exit 1
eval "${_src}"
STUB_CROSS=0
cross_build_is_active() { if [ "${STUB_CROSS}" -eq 1 ]; then return 0; fi; return 1; }
detect_llvm_config() { printf '%s' /usr/bin/llvm-config-23; }
sanitize_llvm_config_for_target() { printf '%s' "$1"; }
validate_detected_llvm_cmake_package() { :; }
detect_vulkan_llvm_cmake_ignore_paths() { printf '%s' ""; }
detect_cross_llvm_cmake_dir() { printf '%s' "${root}/target/lib/cmake/llvm"; }
# The real detector, pointed at a fixture tree instead of /opt/llvm-target.
eval "$(declare -f detect_native_llvm_cmake_dir | sed '1s/detect_native_llvm_cmake_dir/_real_detect_native/')"
NATIVE_ROOT="${root}/shipped"
detect_native_llvm_cmake_dir() { _real_detect_native "${NATIVE_ROOT}"; }
# shellcheck disable=SC2034  # main()'s locals: the lifted resolve_tvm_llvm reads them
_resolve() {
  llvm_config=""; llvm_dir="${1:-}"; llvm_cmake_value="OFF"; llvm_ignore_paths=""
  resolve_tvm_llvm
}

t_case "native: the shipped package, not llvm-config's bootstrap"
STUB_CROSS=0; NATIVE_ROOT="${root}/shipped"; _resolve
t_assert_eq "$(_canon "${root}/shipped/lib/cmake/llvm")|ON" "${llvm_dir}|${llvm_cmake_value}"

t_case "native without a package: llvm-config, as before"
STUB_CROSS=0; NATIVE_ROOT="${root}/empty"; _resolve
t_assert_eq "|/usr/bin/llvm-config-23" "${llvm_dir}|${llvm_cmake_value}"

t_case "native with TVM_LLVM_DIR: that package, and USE_LLVM on (it stayed OFF before)"
STUB_CROSS=0; NATIVE_ROOT="${root}/empty"; _resolve "${root}/lib64-only/lib64/cmake/llvm"
t_assert_eq "$(_canon "${root}/lib64-only/lib64/cmake/llvm")|ON" "${llvm_dir}|${llvm_cmake_value}"

t_case "cross: the target's package, never the build host's"
STUB_CROSS=1; NATIVE_ROOT="${root}/shipped"; _resolve
t_assert_eq "$(_canon "${root}/target/lib/cmake/llvm")|ON" "${llvm_dir}|${llvm_cmake_value}"

t_summary
