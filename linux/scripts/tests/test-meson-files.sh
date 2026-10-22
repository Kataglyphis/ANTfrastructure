#!/usr/bin/env bash
# Generated Meson files must preserve target flags and host-tool fallback order.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/cross-meson.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cross_build_enabled() { return 0; }
setup_linux_cross_env() { export CC=target-cc CXX=target-cxx AR=target-ar STRIP=target-strip; }
cross_target_triplet() { printf test-linux-gnu; }
cross_pkg_config_libdir() { printf /target/pkgconfig; }
cross_target_rust_triple() { printf test-rust-target; }
cross_target_arch() { printf arm64; }
cross_target_cpu_family() { printf aarch64; }
cross_target_cpu() { printf armv8; }
make_meson_cross_rust_wrapper() { printf '%s' "$1"; }
make_host_compiler_wrapper() { printf '%s' "$1"; }
build_deb_multiarch_triplet() { printf host-linux-gnu; }
resolve_build_gcc_tool() {
  case "$1" in
    gcc|g++) return 1 ;;
    *) printf '/host/%s' "$1" ;;
  esac
}

t_case "cross-file emission preserves the target compiler and search paths"
export MESON_RUST_TOOLCHAIN_DIR="${WORK}/rust"
ensure_meson_cross_file "${WORK}/cross.ini"
out="$(cat "${MESON_CROSS_FILE}")"
for field in "c = 'target-cc'" "cpp = 'target-cxx'" "ar = 'target-ar'" \
  "strip = 'target-strip'" "pkg_config_libdir = '/target/pkgconfig'" \
  "CMAKE_LIBRARY_ARCHITECTURE = 'test-linux-gnu'" "cpu_family = 'aarch64'" \
  "cpu = 'armv8'" "rust = '${WORK}/rust/rustc-arm64'"; do
  t_assert_contains "${out}" "${field}"
done

t_case "native-file emission falls back to cc and c++ and wraps only compilers"
export MESON_NATIVE_TOOLCHAIN_DIR="${WORK}/native"
ensure_meson_native_file "${WORK}/native.ini"
out="$(cat "${MESON_NATIVE_FILE}")"
t_assert_contains "${out}" "c = '${WORK}/native/native-cc'"
t_assert_contains "${out}" "cpp = '${WORK}/native/native-cxx'"
t_assert_contains "${out}" "ar = '/host/ar'"
t_assert_contains "${out}" "strip = '/host/strip'"
t_assert_eq /host/cc "$(_meson_native_tool /usr/bin gcc cc)"
t_assert_eq /host/c++ "$(_meson_native_tool /usr/bin g++ c++)"

t_case "a resolver that succeeds with an empty result does not try its alternate"
resolve_build_gcc_tool() { if [ "$1" = gcc ]; then return 0; fi; return 1; }
t_assert_eq "" "$(_meson_native_tool /usr/bin gcc cc)"

t_summary
