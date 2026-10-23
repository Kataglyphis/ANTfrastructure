#!/usr/bin/env bash
# Host tools and target crates must retain separate compilers and conservative plugin exclusions.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gstreamer-fixtures.sh"
SETUP="${1:-${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh}"
RUST="${2:-${TESTS_DIR}/../03-media/build/gstreamer/common/build-gst-plugins-rs.sh}"
t_source_functions "${SETUP}" _gst_prepare_target_cargo_env || exit 1
t_source_functions "${RUST}" _gst_rs_host_cargo_config _gst_rs_riscv_cargo_config _gst_rs_apply_exclusions || exit 1
gst_test_load_functions "${SETUP}" prepare_host_cargo_toolchain_env dump_debug_info || exit 1
gst_test_load_functions "${RUST}" _gst_rs_cargo_config _gst_rs_build_plugins || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bare"
IS_CROSS=0
cross_build_is_active() { return "${IS_CROSS}"; }
cross_build_upper_rust() { printf AARCH64_UNKNOWN_LINUX_GNU; }
cross_build_lower_rust() { printf aarch64_unknown_linux_gnu; }
cross_target_upper_rust() { printf RISCV64GC_UNKNOWN_LINUX_GNU; }
cross_target_lower_rust() { printf riscv64gc_unknown_linux_gnu; }
cross_target_arch() { printf riscv64; }
resolve_host_gcc_for_cargo() { printf /host/gcc; }
resolve_host_gxx_for_cargo() { printf /host/g++; }
prepare_cargo_host_linker_wrapper() { printf /host/cc-wrapper; }
prepare_cargo_host_cxx_wrapper() { printf /host/cxx-wrapper; }
resolve_cross_cc_cxx_for_arch() { export CC=target-gcc CXX=target-g++; }
export_cargo_target_linker() { target_linker_args="$*"; }
cross_bare_bin_path() { printf '%s/bare' "${WORK}"; }
prepare_cargo_target_compiler_wrapper() { printf '/target/%s' "$2"; }
compute_gst_plugins_rs_rust_jobs() { printf 3; }
_host_probe() {
  (
    prepare_host_cargo_toolchain_env >/dev/null
    printf '%s|%s|%s' "${HOST_CC:-unset}" "${CXX_aarch64_unknown_linux_gnu:-unset}" "${target_linker_args:-unset}"
  )
}
t_case "an arm64 build host uses host wrappers and passes only target compilers to the target exporter"
t_assert_eq '/host/cc-wrapper|/host/cxx-wrapper|RISCV64GC_UNKNOWN_LINUX_GNU riscv64gc_unknown_linux_gnu target-gcc target-g++' "$(_host_probe)"
IS_CROSS=1
t_case "native cargo setup leaves host and target overrides untouched"
t_assert_eq 'unset|unset|unset' "$(_host_probe)"
IS_CROSS=0
export BUILD_TYPE_LOWER=release CARGO_BUILD_TARGET=riscv64gc-unknown-linux-gnu CC=target-gcc CXX=target-g++
_config_probe() {
  (
    local initial_path="${PATH}"
    cargo_flags=()
    _gst_rs_cargo_config "${WORK}" >/dev/null
    [ "${PATH}" = "${initial_path}" ] || return 2
    printf '%s|%s|%s|%s|%s' "${cargo_flags[*]}" "${CARGO_BUILD_JOBS}" \
      "${CARGO_TARGET_RISCV64GC_UNKNOWN_LINUX_GNU_LINKER:-unset}" "${CXX_riscv64gc_unknown_linux_gnu:-unset}" "${PKG_CONFIG_ALLOW_SYSTEM_LIBS:-unset}"
  )
}
t_case "standalone RISC-V cargo setup keeps PATH native and exports target wrappers"
t_assert_eq '--release|3|/target/target-gcc-riscv64|/target/target-g++-riscv64|1' "$(_config_probe)"
t_case "explicit cargo parallelism wins over the automatic job count"
t_assert_contains "$(CARGO_BUILD_JOBS=7 _config_probe)" '--release|7|'
t_case "the older host-helper fallback still exports native x86_64 wrappers"
fallback="$(
  unset -f prepare_host_cargo_toolchain_env
  _gst_rs_cargo_config "${WORK}" >/dev/null
  printf '%s|%s' "${CC_x86_64_unknown_linux_gnu:-unset}" "${CXX_x86_64_unknown_linux_gnu:-unset}"
)"
t_assert_eq '/host/cc-wrapper|/host/cxx-wrapper' "${fallback}"

export TARGET_MACHINE_ARCH=riscv64 EXTRA_MESON_ARGS=-Dskia=disabled
export standalone_cargo_toml="${WORK}/Cargo.toml"
dpkg-architecture() { printf riscv64; }
uname() { printf x86_64; }
prune_gst_plugins_rs_workspace_member() { printf 'PRUNE:%s\n' "$2"; }
_gst_rs_exclude() { printf 'EXCLUDE:%s\n' "$3"; }
cargo() { printf 'CARGO:%s\n' "$*"; return "${FAIL_CARGO:-0}"; }
_plugin_probe() {
  (
    declare -a cargo_flags=(--release) default_excludes=()
    export CARGO_BUILD_JOBS=3
    _gst_rs_build_plugins
    printf 'EXCLUDES:%s\n' "${default_excludes[*]}"
  )
}
t_case "the conservative RISC-V build excludes unsupported native dependencies"
out="$(build_all_rs=false _plugin_probe)"
for family in csound skia whisper validate dav1d; do t_assert_contains "${out}" "EXCLUDE:${family}"; done
t_assert_contains "${out}" '--exclude gst-plugin-csound'
t_assert_contains "${out}" '--target riscv64gc-unknown-linux-gnu'
t_case "build-all attempts every member and tolerates member failures for the monorepo installer"
out="$(build_all_rs=true FAIL_CARGO=9 _plugin_probe)"
t_assert_contains "${out}" --keep-going
t_assert_eq 0 "$(build_all_rs=true FAIL_CARGO=9 t_rc _plugin_probe)"
t_case "a conservative cargo failure remains fatal"
t_assert_eq 1 "$(build_all_rs=false FAIL_CARGO=9 t_rc _plugin_probe)"
_debug_probe() {
  (
    export HOST_PYTHON=''
    env() { printf 'ENV:fixture\n'; }
    free() { return 7; }
    df() { return 7; }
    ulimit() { return 7; }
    which() { printf 'LOCATE:%s\n' "$1"; return 7; }
    local tool
    for tool in pip meson ninja rustc cargo clang cc pkg-config; do
      eval "${tool}() { printf 'VERSION:%s\\n' '${tool}'; return 7; }"
    done
    dump_debug_info
  )
}
t_case "debug output attempts every tool even when resource and version probes fail"
out="$(_debug_probe)"
for tool in pip meson ninja rustc cargo clang cc pkg-config; do
  t_assert_contains "${out}" "VERSION:${tool}"
done
t_assert_contains "${out}" '=== end debug info ==='

t_summary
