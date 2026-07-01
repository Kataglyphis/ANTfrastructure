# Source-only helper -- do not execute directly.
# cross-meson.sh - Meson cross-compilation helpers.
# Sourced by cross-env.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi

[ -z "${_CROSS_MESON_LOADED:-}" ] || return 0
_CROSS_MESON_LOADED=1

make_meson_cross_rust_wrapper() {
  local wrapper_path="$1"
  local rustc_bin="$2"
  local rust_target="$3"

  [ -n "${wrapper_path}" ] || return 1
  [ -n "${rustc_bin}" ] || return 1
  [ -n "${rust_target}" ] || return 1

  mkdir -p "$(dirname "${wrapper_path}")"

  local template="${_CROSS_ENV_DIR:-${BASH_SOURCE[0]%/*}}/meson-rust-wrapper.sh"
  if [ -f "${template}" ]; then
    sed -e "s|__RUSTC_BIN__|${rustc_bin}|g" \
        -e "s|__RUST_TARGET__|${rust_target}|g" \
        "${template}" > "${wrapper_path}"
  else
    cat > "${wrapper_path}" <<'HEREDOC_EOF'
#!/usr/bin/env bash
set -eu
want_target='HEREDOC_TARGET'
have_target=false
expect_target_value=false
cargo_managed=false
for arg in "$@"; do
  if [ "${expect_target_value}" = "true" ]; then
    have_target=true
    expect_target_value=false
    continue
  fi
  case "${arg}" in
    --target) expect_target_value=true ;;
    --target=*) have_target=true ;;
    */target/*) cargo_managed=true ;;
  esac
done
if [ "${have_target}" = "true" ]; then exec 'HEREDOC_RUSTC' "$@"; fi
if [ "${cargo_managed}" = "true" ]; then exec 'HEREDOC_RUSTC' "$@"; fi
exec 'HEREDOC_RUSTC' --target "${want_target}" "$@"
HEREDOC_EOF
    sed -i "s|HEREDOC_TARGET|${rust_target}|g; s|HEREDOC_RUSTC|${rustc_bin}|g" "${wrapper_path}"
  fi

  chmod +x "${wrapper_path}"
  printf '%s' "${wrapper_path}"
}
append_cmake_cross_archiver_args() {
  local -n _cmcaa_out=$1
  local archiver_tool_name="${2:-}"

  cross_build_enabled || return 0

  local cross_ar cross_ranlib

  if [ -n "${archiver_tool_name}" ] && command -v "${archiver_tool_name}" >/dev/null 2>&1; then
    cross_ar="$("${archiver_tool_name}" ar)"
    cross_ranlib="$("${archiver_tool_name}" ranlib)"
  else
    cross_ar="${CMAKE_AR:-${AR}}"
    cross_ranlib="${CMAKE_RANLIB:-${RANLIB}}"
  fi

  _cmcaa_out+=(
    "-DCMAKE_AR=${cross_ar}"
    "-DCMAKE_RANLIB=${cross_ranlib}"
    "-DCMAKE_C_COMPILER_AR=${cross_ar}"
    "-DCMAKE_CXX_COMPILER_AR=${cross_ar}"
    "-DCMAKE_C_COMPILER_RANLIB=${cross_ranlib}"
    "-DCMAKE_CXX_COMPILER_RANLIB=${cross_ranlib}"
  )
}

append_cmake_cross_args() {
  local -n _out="$1"

  cross_build_enabled || return 0
  setup_linux_cross_env

  # CMake picks up CMAKE_* from the environment automatically, but explicit -D
  # arguments take precedence and serve as defense-in-depth against stale
  # inherited env vars or CMake toolchain files that might override them.
  _out+=(
    "-DCMAKE_SYSTEM_NAME=Linux"
    "-DCMAKE_SYSTEM_PROCESSOR=${CROSS_TARGET_PROCESSOR}"
    "-DCMAKE_SYSROOT=${CMAKE_SYSROOT:-/}"
    "-DCMAKE_C_COMPILER=${CC}"
    "-DCMAKE_CXX_COMPILER=${CXX}"
    "-DCMAKE_ASM_COMPILER=${CC}"
    "-DCMAKE_AR=${AR}"
    "-DCMAKE_RANLIB=${RANLIB}"
    "-DCMAKE_LIBRARY_ARCHITECTURE=${CROSS_TARGET_TRIPLET}"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY"
    "-DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=ON"
  )
}

ensure_meson_cross_file() {
  local path="${1:-${TMPDIR:-/tmp}/meson-cross-$(cross_target_arch).ini}"
  local triplet pkg_config_libdir exe_wrapper exe_wrapper_line wrapper_candidate
  local rust_target rustc_bin rust_binary_line rust_wrapper rust_wrapper_dir

  cross_build_enabled || return 0
  setup_linux_cross_env

  triplet="$(cross_target_triplet)"
  pkg_config_libdir="$(cross_pkg_config_libdir "${triplet}")"
  rust_target="$(cross_target_rust_triple)"
  rustc_bin="$(command -v rustc 2>/dev/null || true)"
  [ -n "${rustc_bin}" ] || rustc_bin="rustc"
  exe_wrapper=""
  # Some cross builds need to run target-side helpers during Meson setup. Reuse
  # an explicitly provided wrapper first, then fall back to the generic qemu
  # target-runner wrapper installed by pre-setup hooks.
  if [ -n "${MESON_EXE_WRAPPER:-}" ] && [ -x "${MESON_EXE_WRAPPER}" ]; then
    exe_wrapper="${MESON_EXE_WRAPPER}"
  else
    wrapper_candidate="/usr/local/bin/meson-$(cross_target_arch)-exe-wrapper"
    if [ -x "${wrapper_candidate}" ]; then
      exe_wrapper="${wrapper_candidate}"
    fi
  fi
  exe_wrapper_line=""
  if [ -n "${exe_wrapper}" ]; then
    exe_wrapper_line="exe_wrapper = '${exe_wrapper}'"
  fi

  # Meson's Rust cross sanity checks do not reliably infer the target triple
  # from the linker alone. Inject it only when the invocation does not already
  # specify --target so cargo-backed subprojects keep working.
  if [ -n "${rust_target}" ]; then
    rust_wrapper_dir="${MESON_RUST_TOOLCHAIN_DIR:-${TMPDIR:-/tmp}/meson-rust-toolchain}"
    rust_wrapper="$(make_meson_cross_rust_wrapper "${rust_wrapper_dir}/rustc-$(cross_target_arch)" "${rustc_bin}" "${rust_target}")"
    rust_binary_line="rust = '${rust_wrapper}'"
  else
    rust_binary_line="rust = '${rustc_bin}'"
  fi

  # Meson generates a private CMake toolchain for CMake-based subprojects
  # (e.g. libcamera's bundled libyuv) from this cross file's [cmake] section —
  # it does NOT inherit the CMAKE_* environment variables exported by
  # setup_linux_cross_env. Without CMAKE_LIBRARY_ARCHITECTURE, a subproject's
  # find_package(JPEG)/find_library() cannot locate the target's multiarch
  # libraries under /usr/lib/<triplet>, and raw "-l<name>" link flags fail with
  # "unable to find library". Mirroring the multiarch dir here keeps CMake
  # subprojects cross-aware for every consumer, not just libcamera.
  local target_libdir="/usr/lib/${triplet}"

  cat > "${path}" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
${rust_binary_line}
pkg-config = 'pkg-config'
cmake = 'cmake'
${exe_wrapper_line}

[properties]
needs_exe_wrapper = true
sys_root = '/'
pkg_config_libdir = '${pkg_config_libdir}'

[cmake]
CMAKE_LIBRARY_ARCHITECTURE = '${triplet}'
CMAKE_SHARED_LINKER_FLAGS = '-L${target_libdir}'
CMAKE_EXE_LINKER_FLAGS = '-L${target_libdir}'
CMAKE_MODULE_LINKER_FLAGS = '-L${target_libdir}'

[host_machine]
system = 'linux'
cpu_family = '$(cross_target_cpu_family)'
cpu = '$(cross_target_cpu)'
endian = 'little'
EOF

  export MESON_CROSS_FILE="${path}"
}

ensure_meson_native_file() {
  local path="${1:-${TMPDIR:-/tmp}/meson-native-$(cross_build_arch).ini}"
  local host_path build_triplet native_cc native_cxx native_ar native_strip native_pkg_config native_cmake native_pkg_config_libdir
  local native_wrapper_dir native_cc_wrapper native_cxx_wrapper

  cross_build_enabled || return 0

  host_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  build_triplet="$(build_deb_multiarch_triplet)"
  if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
    native_cc="$(resolve_build_gcc_tool gcc 2>/dev/null || resolve_build_gcc_tool cc 2>/dev/null || true)"
    native_cxx="$(resolve_build_gcc_tool g++ 2>/dev/null || resolve_build_gcc_tool c++ 2>/dev/null || true)"
    native_ar="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
    native_strip="$(resolve_build_gcc_tool strip 2>/dev/null || true)"
  else
    native_cc="$(PATH="${host_path}" command -v gcc || PATH="${host_path}" command -v cc || true)"
    native_cxx="$(PATH="${host_path}" command -v g++ || PATH="${host_path}" command -v c++ || true)"
    native_ar="$(PATH="${host_path}" command -v ar || true)"
    native_strip="$(PATH="${host_path}" command -v strip || true)"
  fi
  native_pkg_config="$(PATH="${host_path}" command -v pkg-config || true)"
  native_cmake="$(PATH="${host_path}" command -v cmake || true)"
  if [ -n "${build_triplet}" ]; then
    native_pkg_config_libdir="/usr/lib/${build_triplet}/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  else
    native_pkg_config_libdir="/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:/usr/share/pkgconfig"
  fi

  native_wrapper_dir="${MESON_NATIVE_TOOLCHAIN_DIR:-${TMPDIR:-/tmp}/meson-native-toolchain}"
  mkdir -p "${native_wrapper_dir}"

  if [ -n "${native_cc}" ]; then
    native_cc_wrapper="$(make_host_compiler_wrapper "${native_wrapper_dir}/native-cc" "${native_cc}" "${host_path}")"
    native_cc="${native_cc_wrapper}"
  fi

  if [ -n "${native_cxx}" ]; then
    native_cxx_wrapper="$(make_host_compiler_wrapper "${native_wrapper_dir}/native-cxx" "${native_cxx}" "${host_path}")"
    native_cxx="${native_cxx_wrapper}"
  fi

  cat > "${path}" <<EOF
[binaries]
c = '${native_cc}'
cpp = '${native_cxx}'
ar = '${native_ar}'
strip = '${native_strip}'
pkg-config = '${native_pkg_config}'
cmake = '${native_cmake}'

[properties]
pkg_config_libdir = '${native_pkg_config_libdir}'
EOF

  export MESON_NATIVE_FILE="${path}"
}

append_meson_cross_flags() {
  local out_name="$1"
  local -n meson_cross_flags_ref="${out_name}"

  cross_build_enabled || return 0
  ensure_meson_cross_file
  meson_cross_flags_ref+=(--cross-file "${MESON_CROSS_FILE}")
}

append_meson_native_flags() {
  local out_name="$1"
  local -n meson_native_flags_ref="${out_name}"

  cross_build_enabled || return 0
  ensure_meson_native_file
  meson_native_flags_ref+=(--native-file "${MESON_NATIVE_FILE}")
}
