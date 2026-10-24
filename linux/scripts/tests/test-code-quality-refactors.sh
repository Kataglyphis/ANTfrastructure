#!/usr/bin/env bash
# Resolution order and archive fallbacks are covered without downloading a real SDK.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
source "${TESTS_DIR}/../01-core/cross-python.sh"
mkdir -p "${WORK}/venv/bin"
for executable in media uv venv/bin/python; do
  printf '#!/bin/sh\nexit 0\n' > "${WORK}/${executable}"
  chmod +x "${WORK}/${executable}"
done
MEDIA_HOST_PYTHON="${WORK}/media"
UV_PYTHON="${WORK}/uv"
VIRTUAL_ENV="${WORK}/venv"
export PYTHON_MAJOR_MINOR=nonexistent
export PYTHON_VERSION=fixture
version_major_minor() { printf 'version conversion must be lazy\n' >&2; return 1; }
t_case "explicit media interpreter wins without resolving lower priority versions"
t_assert_eq "${MEDIA_HOST_PYTHON}" "$(host_python_bin)"
MEDIA_HOST_PYTHON="${WORK}/missing"
t_case "an invalid override falls through to uv"
t_assert_eq "${UV_PYTHON}" "$(host_python_bin)"
UV_PYTHON=''
t_case "the virtual environment precedes version-derived paths"
t_assert_eq "${VIRTUAL_ENV}/bin/python" "$(host_python_bin)"
VIRTUAL_ENV=''
export PYTHON_VERSION=''
t_case "ordinary PATH lookup remains the final fallback"
t_assert_eq "$(command -v python3)" "$(host_python_bin)"

info() { :; }
source "${TESTS_DIR}/../01-core/abseil-headers.sh"
mkdir -p "${WORK}/source/abseil-cpp-fixture/absl/types"
printf 'fixture\n' > "${WORK}/source/abseil-cpp-fixture/absl/types/span.h"
command tar -czf "${WORK}/headers.tar.gz" -C "${WORK}/source" abseil-cpp-fixture
download_file() { cp "${WORK}/headers.tar.gz" "$2"; }
download_verified_file() { cp "${WORK}/headers.tar.gz" "$3"; }
export ABSEIL_VERSION=fixture
export ABSEIL_COMMIT=fixture
export ABSEIL_TARBALL_STREAM_SHA256=fixture
for method in wildcard manifest; do
  tar() {
    if [ "${method}" = manifest ] && [[ " $* " = *' --wildcards '* ]]; then
      return 1
    fi
    command tar "$@"
  }
  t_case "${method} extraction verifies the installed marker"
  t_assert_eq 0 "$(t_rc install_abseil_headers "${WORK}/${method}")"
  t_assert_eq fixture "$(cat "${WORK}/${method}/absl/types/span.h")"
done
unset -f tar
t_case "an existing marker avoids a failed download"
download_verified_file() { return 1; }
t_assert_eq 0 "$(t_rc install_abseil_headers "${WORK}/wildcard")"
t_case "download failure cannot report successful installation"
t_assert_eq 1 "$(t_rc install_abseil_headers "${WORK}/missing-headers")"
for fn in _gcc_compiler_prefix _detect_gcc_cxxabi_header; do
  eval "$(t_fn_src "${TESTS_DIR}/../05-frameworks/tvm-llvm-compat.sh" "${fn}")"
done
t_case "compiler-prefix lookup follows the executable symlink"
mkdir -p "${WORK}/gcc/bin"
printf '#!/bin/sh\nprintf "16.1.0\\n"\n' > "${WORK}/gcc/bin/g++"
chmod +x "${WORK}/gcc/bin/g++"
ln -s "${WORK}/gcc/bin/g++" "${WORK}/compiler"
t_assert_eq "${WORK}/gcc" "$(_gcc_compiler_prefix "${WORK}/compiler")"

for fn in _ffmpeg_append_pkg_features _ffmpeg_probe_core_codecs; do
  eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh" "${fn}")"
done
ffmpeg_probe_pkg_config_feature() {
  case "$1" in libass) return 1 ;; *) return 0 ;; esac
}
for codec in libmp3lame libopus libvorbis libvpx libx264; do
  eval "ffmpeg_probe_${codec}() { return 0; }"
done
t_case "codec tables preserve configure flag order and omit rejected features"
declare -a feature_flags=()
_ffmpeg_probe_core_codecs feature_flags
t_assert_eq '--enable-libfreetype --enable-libharfbuzz --enable-libfontconfig --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx --enable-libx264 --enable-gnutls --enable-libaom --enable-libdav1d --enable-libsvtav1 --enable-libwebp --enable-libvmaf' "${feature_flags[*]}"

t_source_functions "${TESTS_DIR}/../06-packaging/smoke-common.sh" smoke_with_compiled_object
t_source_functions "${TESTS_DIR}/../06-packaging/smoke-android.sh" _check_ndk_object _check_ndk_compiler
pass() { printf 'PASS:%s\n' "$*"; }
fail() { printf 'FAIL:%s\n' "$*"; }
smoke_elf_machine_of() { printf '%s' "${OBJECT_MACHINE}"; }
smoke_elf_machine_grep() { printf '%s' AArch64; }
smoke_host_arch() { printf '%s' "$1"; }
export ANDROID_API_LEVEL=34
mkdir -p "${WORK}/ndk/bin"
printf '#!/bin/sh\nexit 0\n' > "${WORK}/ndk/bin/aarch64-linux-android34-clang"
chmod +x "${WORK}/ndk/bin/aarch64-linux-android34-clang"
OBJECT_MACHINE=AArch64
t_case "NDK object verification accepts the requested architecture"
t_assert_contains "$(t_out _check_ndk_compiler "${WORK}/ndk" aarch64)" 'PASS:NDK clang aarch64: compiles'
OBJECT_MACHINE=X86-64
t_case "an existing compiler cannot pass with an object for another architecture"
t_assert_contains "$(t_out _check_ndk_compiler "${WORK}/ndk" aarch64)" "does not match target"
smoke_elf_machine_grep() { return 1; }
t_case "an unknown NDK target cannot match an empty ELF pattern"
t_assert_contains "$(t_out _check_ndk_compiler "${WORK}/ndk" aarch64)" 'no ELF-machine mapping'

eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/ffmpeg/build-ffmpeg.sh" _ffmpeg_enqueue_unresolved)"
export FFMPEG_PREFIX="${WORK}/ffmpeg"
elf_unresolved_needed() { printf '%s\n' libfirst.so '' libsecond.so libfirst.so; }
declare -a pending_libraries=()
declare -A seen=()
t_case "SDK dependency traversal queues each unresolved soname once, in discovery order"
_ffmpeg_enqueue_unresolved pending_libraries fixture
_ffmpeg_enqueue_unresolved pending_libraries fixture
t_assert_eq 'libfirst.so libsecond.so' "${pending_libraries[*]}"
t_assert_eq 2 "${#seen[@]}"

for fn in _media_load_modules _media_setup_rust_cache _media_assert_critical_fns media_common_init; do
  eval "$(t_fn_src "${TESTS_DIR}/../03-media/core/common.sh" "${fn}")"
done
mkdir -p "${WORK}/core"
printf 'source_modules_framework() { :; }\n' > "${WORK}/core/modules.sh"
_media_find_core_dir() { printf '%s' "${WORK}/core"; }
declare -a media_trace=()
source_module() {
  media_trace+=("$1")
  if [ "$1" = common.sh ]; then
    log() { :; }
    cross_build_is_active() { return 1; }
    mem_capped_jobs() { printf '1'; }
    return 1
  fi
}
setup_ccache() { media_trace+=(ccache); }
setup_lld_linker() { media_trace+=(linker); }
setup_sccache() { media_trace+=(sccache); }
sccache() { printf 'Compile requests 0\n'; }
media_load_arch_flags() { media_trace+=(arch-flags); }
export ENABLE_SCCACHE_RUST=1
t_case "media bootstrap preserves module and cache initialization order despite a benign module status"
media_common_init "${WORK}" 2>/dev/null
t_assert_eq 'common.sh cross-env.sh logging.sh build-helpers.sh guard-helpers.sh parallelism.sh cross-meson.sh cross-apt.sh downloads.sh compiler-cache.sh ccache linker qnn-sdk.sh sccache compiler-resolution.sh python-host.sh cmake-cache-linker.sh abseil-headers.sh arch-flags' "${media_trace[*]}"
_missing_media_bootstrap() {
  unset -f cross_build_is_active
  source_module() { return 1; }
  media_common_init "${WORK}"
}
t_case "a missing critical media helper still fails the bootstrap"
t_assert_eq 1 "$(t_rc _missing_media_bootstrap)"
t_assert_contains "$(t_out _missing_media_bootstrap)" 'missing: cross_build_is_active'

for fn in _cross_run_targets for_each_cross_target _cross_fetch_cmake_source; do
  eval "$(t_fn_src "${TESTS_DIR}/../01-core/cross-env.sh" "${fn}")"
done
build_arch_oci() { printf 'arm64'; }
arch_list_csv_normalize() { printf '%s' "$1"; }
cross_targets_effective_raw() { printf 'amd64,arm64,riscv64'; }
declare -a target_trace=()
record_target() {
  target_trace+=("$1")
  case "$1" in amd64) return 7 ;; *) return 0 ;; esac
}
t_case "cross-target callbacks skip the build host and retain a failure after later success"
callback_rc=0
for_each_cross_target record_target || callback_rc=$?
t_assert_eq 'amd64 riscv64' "${target_trace[*]}"
t_assert_eq 7 "${callback_rc}"
target_trace=()
for_each_cross_target record_target --include-amd64 'arm64,riscv64'
t_assert_eq 'arm64 riscv64' "${target_trace[*]}"
t_assert_eq 2 "$(t_rc for_each_cross_target)"

git() { return 1; }
download_and_extract() {
  case "$1" in
    good) printf 'fixture\n' > "$2/CMakeLists.txt"; return 0 ;;
    *) return 1 ;;
  esac
}
mkdir -p "${WORK}/cmake-source"
t_case "source mirrors fall through both archive and git failures before success"
t_assert_eq 0 "$(t_rc _cross_fetch_cmake_source fixture 'bad|git+https://invalid#fixture|good' "${WORK}/cmake-source")"
t_assert_ok test -f "${WORK}/cmake-source/CMakeLists.txt"
t_case "exhausting every source mirror cannot return success"
t_assert_eq 1 "$(t_rc _cross_fetch_cmake_source fixture bad "${WORK}/cmake-source")"

eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/opencv/build-opencv.sh" _opencv_gstreamer_libdir)"
arch_deb_multiarch_triplet_for() { printf aarch64-linux-gnu; }
pkg-config() { printf '%s' "${PKG_LIBDIR}"; }
export TARGET_ARCH=arm64
GST_PREFIX="${WORK}/gstreamer with spaces"
PKG_LIBDIR="${WORK}/pkgconfig-lib"
mkdir -p "${PKG_LIBDIR}" "${GST_PREFIX}/lib/aarch64-linux-gnu" "${GST_PREFIX}/lib"
for libdir in "${PKG_LIBDIR}" "${GST_PREFIX}/lib/aarch64-linux-gnu" "${GST_PREFIX}/lib"; do
  touch "${libdir}/libgstreamer-1.0.so"
done
t_case "OpenCV prefers an actual pkgconfig library, then the triplet directory, then flat lib"
t_assert_eq "${PKG_LIBDIR}" "$(_opencv_gstreamer_libdir "${GST_PREFIX}")"
rm "${PKG_LIBDIR}/libgstreamer-1.0.so"
t_assert_eq "${GST_PREFIX}/lib/aarch64-linux-gnu" "$(_opencv_gstreamer_libdir "${GST_PREFIX}")"
rm "${GST_PREFIX}/lib/aarch64-linux-gnu/libgstreamer-1.0.so"
t_assert_eq "${GST_PREFIX}/lib" "$(_opencv_gstreamer_libdir "${GST_PREFIX}")"
rm "${GST_PREFIX}/lib/libgstreamer-1.0.so"
mkdir -p "${GST_PREFIX}/share/gdb" "${GST_PREFIX}/custom"
touch "${GST_PREFIX}/share/gdb/libgstreamer-1.0.so" "${GST_PREFIX}/custom/libgstreamer-1.0.so"
t_case "the recursive OpenCV fallback excludes debugger mirrors"
t_assert_eq "${GST_PREFIX}/custom" "$(_opencv_gstreamer_libdir "${GST_PREFIX}")"
rm "${GST_PREFIX}/custom/libgstreamer-1.0.so"
t_assert_eq '' "$(_opencv_gstreamer_libdir "${GST_PREFIX}")"

for fn in init_defaults parse_common_args validate_build_type; do
  eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/onnxruntime/build/lib/common.sh" "${fn}")"
done
err() { printf '%s\n' "$*" >&2; exit 87; }
_parse_ort() { ( parse_common_args "$@" ); }
t_case "ORT CLI values and configuration aliases retain their precedence"
parse_common_args --ort-version fixture-ort --wasm-config Debug --genai-version fixture-genai --genai-config MinSizeRel --skip-genai
t_assert_eq fixture-ort "${ORT_VERSION}"
t_assert_eq fixture-genai "${GENAI_VERSION}"
t_assert_eq Debug "${WASM_CONFIG}"
t_assert_eq MinSizeRel "${GENAI_CONFIG}"
t_assert_eq false "${BUILD_GENAI}"
for alias in --build-type --native-cpu-config --native-config; do
  parse_common_args "${alias}" RelWithDebInfo
  t_assert_eq RelWithDebInfo "${NATIVE_CPU_CONFIG}"
done
t_case "every valued ORT option rejects a missing value with its own name"
for option in --ort-version --build-type --native-cpu-config --native-config --wasm-config --genai-version --genai-config; do
  t_assert_eq 87 "$(t_rc _parse_ort "${option}")"
  t_assert_contains "$(t_out parse_common_args "${option}")" "${option} requires a value"
done
t_assert_eq 87 "$(t_rc _parse_ort --unknown)"
t_assert_eq 87 "$(t_rc _parse_ort --wasm-config invalid)"

t_source_functions "${TESTS_DIR}/../03-media/core/common.sh" media_missing_dev_symlink || exit 1
eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/armnn/build-armnn.sh" _armnn_link_openmp)"
mkdir -p "${WORK}/openmp links" "${WORK}/openmp-source"
touch "${WORK}/openmp links/libgomp.so.1" "${WORK}/openmp-source/libgomp.so.1"
t_case "Arm NN's native OpenMP symlink stays relative to its destination directory"
_armnn_link_openmp "${WORK}/openmp links/libgomp.so" libgomp.so.1 fixture >/dev/null
t_assert_eq libgomp.so.1 "$(readlink "${WORK}/openmp links/libgomp.so")"
rm "${WORK}/openmp links/libgomp.so"
t_case "the cross OpenMP symlink points at the explicit target runtime"
_armnn_link_openmp "${WORK}/openmp links/libgomp.so" "${WORK}/openmp-source/libgomp.so.1" fixture >/dev/null
t_assert_eq "${WORK}/openmp-source/libgomp.so.1" "$(readlink "${WORK}/openmp links/libgomp.so")"
t_case "an existing linker file is preserved and missing runtimes produce no link"
rm "${WORK}/openmp links/libgomp.so"
printf 'existing\n' > "${WORK}/openmp links/libgomp.so"
_armnn_link_openmp "${WORK}/openmp links/libgomp.so" libgomp.so.1 fixture >/dev/null
t_assert_eq existing "$(cat "${WORK}/openmp links/libgomp.so")"
_armnn_link_openmp "${WORK}/openmp links/missing.so" missing.so.1 fixture >/dev/null
t_assert_fails test -L "${WORK}/openmp links/missing.so"

eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/armnn/build-arm-compute-library.sh" _acl_install_artifacts)"
die() { printf '%s\n' "$*" >&2; exit 87; }
mkdir -p "${WORK}/acl-source/build" "${WORK}/acl-source/include" "${WORK}/acl-source/arm_compute"
touch "${WORK}/acl-source/build/libarm_compute.so" "${WORK}/acl-source/include/acl_version.h" "${WORK}/acl-source/arm_compute/core.h"
export ACL_INSTALL_DIR="${WORK}/acl-install"
_install_acl() { ( cd "${WORK}/acl-source" && _acl_install_artifacts ); }
t_case "ACL installation accepts a shared-only build and copies both header roots"
t_assert_ok _install_acl
t_assert_ok test -f "${ACL_INSTALL_DIR}/lib/libarm_compute.so"
t_assert_ok test -f "${ACL_INSTALL_DIR}/include/arm_compute/core.h"
t_assert_ok test -f "${ACL_INSTALL_DIR}/include/acl_version.h"
ACL_INSTALL_DIR="${WORK}/acl-no-library"
rm "${WORK}/acl-source/build/libarm_compute.so"
t_case "the best-effort ACL copies cannot hide an absent runtime library"
t_assert_eq 87 "$(t_rc _install_acl)"
t_assert_contains "$(t_out _install_acl)" 'no libarm_compute'
ACL_INSTALL_DIR="${WORK}/acl-no-headers"
touch "${WORK}/acl-source/build/libarm_compute.so"
rm -r "${WORK}/acl-source/arm_compute"
t_case "an ACL library without its API headers cannot pass installation verification"
t_assert_eq 87 "$(t_rc _install_acl)"
t_assert_contains "$(t_out _install_acl)" 'arm_compute headers missing'

eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/android/build-android-from-source.sh" _cerbero_soundtouch_archive_url)"
t_case "soundtouch archive resolution expands both supported recipe placeholder styles"
t_assert_eq 'https://codeberg.org/soundtouch/archive/fixture.tar.gz' "$(_cerbero_soundtouch_archive_url fixture soundtouch 'https://codeberg.org/%(name)s/archive/%(version)s.tar.gz')"
t_assert_eq 'https://codeberg.org/soundtouch/archive/fixture.tar.gz' "$(_cerbero_soundtouch_archive_url fixture soundtouch 'https://codeberg.org/{name}/archive/{version}.tar.gz')"
t_case "soundtouch cannot repin another host, an unknown placeholder or unsafe recipe values"
t_assert_eq 1 "$(t_rc _cerbero_soundtouch_archive_url fixture soundtouch https://other.invalid/soundtouch/archive/fixture.tar.gz)"
t_assert_eq 1 "$(t_rc _cerbero_soundtouch_archive_url fixture soundtouch 'https://codeberg.org/{unknown}/archive/fixture.tar.gz')"
t_assert_eq 1 "$(t_rc _cerbero_soundtouch_archive_url 'bad/value' soundtouch 'https://codeberg.org/soundtouch/archive/{version}.tar.gz')"

eval "$(t_fn_src "${TESTS_DIR}/../03-media/build/gstreamer/android/build-android-from-source.sh" cerbero_state_empty)"
_cerbero_state="${WORK}/cerbero cache"
mkdir -p "${_cerbero_state}/sources/local" "${_cerbero_state}/build"
touch "${_cerbero_state}/state.cache"
t_case "cerbero cache clearing keeps the mountpoint and removes only its contents"
cerbero_state_empty "${_cerbero_state}"
t_assert_ok test -d "${_cerbero_state}"
t_assert_eq "" "$(find "${_cerbero_state}" -mindepth 1 -maxdepth 1 -print -quit)"

t_source_functions "${TESTS_DIR}/../06-packaging/validate-compilers.sh" _artifact_source_check_swapped_gcc _vc_elf_machine_header _vc_elf_header_matches || exit 1
mkdir -p "${WORK}/swapped-gcc/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$DUMP_TRIPLE"\n' > "${WORK}/swapped-gcc/bin/gcc"
chmod +x "${WORK}/swapped-gcc/bin/gcc"
export DUMP_TRIPLE=aarch64-linux-gnu
arch_to_elf_machine() { case "$1" in arm64) printf AArch64 ;; *) return 1 ;; esac; }
readelf() { printf 'Machine: %s\n' "${GCC_ELF_MACHINE}"; }
ERROR_COUNT=0
validate_fail() { ERROR_COUNT=$((ERROR_COUNT + 1)); }
t_case "the swapped GCC accepts its explicit target triple"
t_assert_contains "$(_artifact_source_check_swapped_gcc arm64 "${WORK}/swapped-gcc" /native/gcc)" 'swap completed'
DUMP_TRIPLE=unknown
GCC_ELF_MACHINE=AArch64
t_case "a non-runnable swapped GCC can be verified by its ELF machine"
t_assert_contains "$(_artifact_source_check_swapped_gcc arm64 "${WORK}/swapped-gcc" /native/gcc)" 'cross-built ELF for arm64'
GCC_ELF_MACHINE=X86-64
t_case "wrong or unknown target machines cannot pass the swapped GCC fallback"
_artifact_source_check_swapped_gcc arm64 "${WORK}/swapped-gcc" /native/gcc
t_assert_eq 1 "${ERROR_COUNT}"
_artifact_source_check_swapped_gcc unknown "${WORK}/swapped-gcc" /native/gcc
t_assert_eq 2 "${ERROR_COUNT}"

t_summary
