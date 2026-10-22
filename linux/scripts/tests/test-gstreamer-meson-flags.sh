#!/usr/bin/env bash
# Cross-build refusals and target flags stay armed when the monorepo configuration is decomposed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/gstreamer-fixtures.sh"
SUBJECT="${1:-${TESTS_DIR}/../03-media/build/gstreamer/common/build-gstreamer-monorepo.sh}"
for fn in _gst_monorepo_riscv_flags _gst_monorepo_wrap_flags; do
  if rg -q "^${fn}\(\)" "${SUBJECT}"; then
    eval "$(t_fn_src "${SUBJECT}" "${fn}")"
  fi
done
gst_test_load_functions "${SUBJECT}" _gst_monorepo_arch_flags _gst_monorepo_python_config _gst_monorepo_cross_flags || exit 1
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export BUILD_DIR="${WORK}" BUILD_MODE=cross TARGET_MACHINE_ARCH=riscv64 GST_RS_BUILD_ALL=false
IS_CROSS=0
cross_build_is_active() { return "${IS_CROSS}"; }
cross_target_arch() { printf riscv64; }
append_meson_arg() { MESON_FLAGS+=("$1"); }
declare -a MESON_FLAGS=()
t_case "the reduced RISC-V Rust build still disables unsupported plugins"
_gst_monorepo_arch_flags >/dev/null
flags="$(printf '%s\n' "${MESON_FLAGS[@]}")"
for required in -Drs=disabled -Dgstreamer:ptp-helper=disabled -Dglib:tests=false \
  -Dgst-plugins-rs:whisper=disabled -Dgst-plugins-rs:validate=disabled -Dgst-plugins-rs:csound=disabled -Dgst-plugins-rs:skia=disabled; do
  t_assert_contains "${flags}" "${required}"
done
t_case "ARM keeps Rust enabled and its conservative plugin selection"
TARGET_MACHINE_ARCH=aarch64 BUILD_MODE=native IS_CROSS=1
MESON_FLAGS=()
_gst_monorepo_arch_flags >/dev/null
flags="$(printf '%s\n' "${MESON_FLAGS[@]}")"
t_assert_contains "${flags}" -Drs=enabled
t_assert_contains "${flags}" -Dgst-plugins-rs:csound=disabled

prepare_calls=0
prepare_cross_python_build_config() { prepare_calls=$((prepare_calls + 1)); }
cross_target_python_libdir() { printf /fixture/python/lib; }
cross_target_python_pkgconfig_dir() { printf /fixture/python/lib/pkgconfig; }
export python_feature=enabled PKG_CONFIG_PATH=/fixture/existing
IS_CROSS=0
MESON_FLAGS=()
t_case "cross Python uses target metadata and prepends its pkgconfig directory only once"
_gst_monorepo_python_config
_gst_monorepo_python_config
t_assert_eq 2 "${prepare_calls}"
t_assert_contains "${MESON_FLAGS[*]}" -Dgst-python:libpython-dir=/fixture/python/lib
t_assert_eq '/fixture/python/lib/pkgconfig:/fixture/existing' "${PKG_CONFIG_PATH}"
IS_CROSS=1
MESON_FLAGS=()
_gst_monorepo_python_config
t_assert_eq 3 "${prepare_calls}"
t_assert_eq 0 "${#MESON_FLAGS[@]}"

resolved_calls=0
resolve_cross_cc_cxx_for_arch() { resolved_calls=$((resolved_calls + 1)); export CC=target-gcc CXX=target-g++; }
append_meson_cross_flags() { MESON_FLAGS+=(--cross-file=fixture); }
append_meson_native_flags() { MESON_FLAGS+=(--native-file=fixture); }
dump_debug_info() { :; }
export BUILD_MODE=cross CC='' CXX='' CROSS_PYTHON_BUILD_CONFIG=/fixture/python.json
export GSTREAMER_ENABLE_PYTHON_BINDINGS=true MESON_CROSS_FILE="${WORK}/cross.ini" EXTRA_MESON_ARGS='--wrap-mode=forcefallback'
printf '[properties]\npkg_config_libdir = ["/host/pkgconfig"]\nkeep = true\n' > "${MESON_CROSS_FILE}"
MESON_FLAGS=()
t_case "cross flags resolve both compilers, remove host pkgconfig pins and preserve explicit wrap policy"
_gst_monorepo_cross_flags
t_assert_eq 1 "${resolved_calls}"
t_assert_eq target-gcc "${CC}"
t_assert_eq target-g++ "${CXX}"
t_assert_contains "${MESON_FLAGS[*]}" -Dgst-python:python.build_config=/fixture/python.json
t_assert_eq '--wrap-mode=forcefallback --force-fallback-for=pygobject-3.0' "${EXTRA_MESON_ARGS}"
t_assert_eq $'[properties]\nkeep = true' "$(cat "${MESON_CROSS_FILE}")"
t_summary
