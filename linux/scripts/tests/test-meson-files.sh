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

t_case "with a compiler cache the compilers become ['launcher', 'cc'] lists, which Meson runs as one command"
compiler_cache_launcher() { printf '/opt/scripts/core/sccache-launcher.sh'; }
ensure_meson_cross_file "${WORK}/cross-cached.ini"
out="$(cat "${MESON_CROSS_FILE}")"
t_assert_contains "${out}" "c = ['/opt/scripts/core/sccache-launcher.sh', 'target-cc']" "GStreamer's C compiles bypassed sccache until 2026-10-28: Meson ignores CMAKE_*_COMPILER_LAUNCHER"
t_assert_contains "${out}" "cpp = ['/opt/scripts/core/sccache-launcher.sh', 'target-cxx']"
t_assert_contains "${out}" "rust_ld = 'target-cc'" "rustc links through the plain cc: Meson would otherwise pass the launcher as -C linker= and rustc's link step fails (2026-10-29)"
t_assert_contains "${out}" "ar = 'target-ar'" "only the compilers are wrapped"
ensure_meson_native_file "${WORK}/native-cached.ini"
t_assert_contains "$(cat "${MESON_NATIVE_FILE}")" "c = ['/opt/scripts/core/sccache-launcher.sh', '${WORK}/native/native-cc']" "the host half too"
unset -f compiler_cache_launcher
unset MESON_CROSS_FILE MESON_NATIVE_FILE

t_case "a NATIVE build gets a native file with the cached compilers, and none without a cache"
cross_build_enabled() { return 1; }
flags=(); append_meson_native_flags flags
t_assert_eq "" "${flags[*]:-}" "no launcher, no file: Meson takes CC/CXX as before"
compiler_cache_launcher() { printf '/opt/scripts/core/sccache-launcher.sh'; }
flags=(); CC=cc CXX=c++ TMPDIR="${WORK}" append_meson_native_flags flags
t_assert_eq "--native-file ${WORK}/meson-native-cache.ini" "${flags[*]:-}" "GStreamer and libcamera call this in native mode too"
t_assert_contains "$(cat "${WORK}/meson-native-cache.ini")" "c = ['/opt/scripts/core/sccache-launcher.sh', '$(command -v cc)']" "the resolved compiler behind the launcher"
unset -f compiler_cache_launcher
cross_build_enabled() { return 0; }

t_case "a resolver that succeeds with an empty result does not try its alternate"
resolve_build_gcc_tool() { if [ "$1" = gcc ]; then return 0; fi; return 1; }
t_assert_eq "" "$(_meson_native_tool /usr/bin gcc cc)"

t_summary
