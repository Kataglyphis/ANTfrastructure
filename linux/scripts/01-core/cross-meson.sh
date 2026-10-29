# shellcheck shell=bash
# Meson and CMake cross-compilation helpers, sourced by cross-env.sh.

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

  if [ -z "${wrapper_path}" ] || [ -z "${rustc_bin}" ] || [ -z "${rust_target}" ]; then
    return 1
  fi

  mkdir -p "$(dirname "${wrapper_path}")"

  local template="${_CROSS_ENV_DIR:-${BASH_SOURCE[0]%/*}}/meson-rust-wrapper.sh"
  if [ ! -f "${template}" ]; then
    err "meson-rust-wrapper template not found: ${template}"
  fi
  sed -e "s|__RUSTC_BIN__|${rustc_bin}|g" \
      -e "s|__RUST_TARGET__|${rust_target}|g" \
      "${template}" > "${wrapper_path}"

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

  # Explicit -D wins over stale inherited env vars or toolchain files.
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

# <compiler>: the Meson binaries entry; with a compiler cache the list form ['launcher', 'cc'], which Meson runs as one command (2026-10-28: GStreamer's C compiles bypassed sccache).
_meson_compiler_entry() {
  local launcher=""
  if command -v compiler_cache_launcher >/dev/null 2>&1; then
    launcher="$(compiler_cache_launcher 2>/dev/null || true)"
  fi
  if [ -n "${launcher}" ]; then printf "['%s', '%s']" "${launcher}" "$1"; else printf "'%s'" "$1"; fi
}

# <cc> <cxx> <ar> <strip>: the head of a [binaries] section, shared by the cross and the native file.
_meson_binaries_head() {
  printf '[binaries]\nc = %s\ncpp = %s\nar = '"'"'%s'"'"'\nstrip = '"'"'%s'"'"'\n' \
    "$(_meson_compiler_entry "$1")" "$(_meson_compiler_entry "$2")" "$3" "$4"
  # Without rust_ld Meson derives rustc's linker from the c entry, i.e. "-C linker=<launcher> -C link-arg=<cc>", and gst-plugins-rs cannot link (chain 5, 2026-10-29).
  printf 'rust_ld = '"'"'%s'"'"'\n' "$1"
}

_write_meson_cross_file() {
  local path="$1" triplet="$2" pkg_config_libdir="$3" rust_binary_line="$4" exe_wrapper_line="$5"
  # CMake subprojects get their toolchain from [cmake] below, not from the exported CMAKE_* env.
  local target_libdir="/usr/lib/${triplet}"

  cat > "${path}" <<EOF
$(_meson_binaries_head "${CC}" "${CXX}" "${AR}" "${STRIP}")
${rust_binary_line}
pkg-config = 'pkg-config'
cmake = 'cmake'
${exe_wrapper_line}

[properties]
needs_exe_wrapper = true
sys_root = '/'
pkg_config_libdir = '${pkg_config_libdir}'

# The custom cross-GCC with --sysroot=/ does NOT search the Debian multiarch
# dirs (/usr/include, /usr/include/<triplet>) where apt installs :<arch> target
# dev headers, and meson CROSS builds do NOT apply the host CFLAGS/CPPFLAGS env
# to the TARGET (host_machine) compiler — so meson's own cc.get_define /
# has_header checks fail to find e.g. openssl's arch-specific opensslconf.h,
# hard-aborting plugins like gst-plugins-good's HLS. Give the target compiler
# those dirs here (lowest priority via -idirafter so GCC's own headers win).
[built-in options]
c_args = ['-idirafter', '/usr/include/${triplet}', '-idirafter', '/usr/include']
cpp_args = ['-idirafter', '/usr/include/${triplet}', '-idirafter', '/usr/include']

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
}

ensure_meson_cross_file() {
  local path; path="${1:-${TMPDIR:-/tmp}/meson-cross-$(cross_target_arch).ini}"
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
  # Target-side helpers during setup need a runner: MESON_EXE_WRAPPER, else the pre-setup qemu wrapper.
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

  # Meson's Rust sanity check cannot infer the target, so the wrapper adds --target when absent.
  if [ -n "${rust_target}" ]; then
    rust_wrapper_dir="${MESON_RUST_TOOLCHAIN_DIR:-${TMPDIR:-/tmp}/meson-rust-toolchain}"
    rust_wrapper="$(make_meson_cross_rust_wrapper "${rust_wrapper_dir}/rustc-$(cross_target_arch)" "${rustc_bin}" "${rust_target}")"
    rust_binary_line="rust = '${rust_wrapper}'"
  else
    rust_binary_line="rust = '${rustc_bin}'"
  fi

  _write_meson_cross_file "${path}" "${triplet}" "${pkg_config_libdir}" "${rust_binary_line}" "${exe_wrapper_line}"

  export MESON_CROSS_FILE="${path}"
}

_meson_native_tool() {
  local host_path="$1" tool
  shift
  for tool in "$@"; do
    if command -v resolve_build_gcc_tool >/dev/null 2>&1; then
      resolve_build_gcc_tool "${tool}" 2>/dev/null && return 0
    else
      PATH="${host_path}" command -v "${tool}" && return 0
    fi
  done
  return 0
}

ensure_meson_native_file() {
  local path; path="${1:-${TMPDIR:-/tmp}/meson-native-$(cross_build_arch).ini}"
  local host_path build_triplet native_cc native_cxx native_ar native_strip native_pkg_config native_cmake native_pkg_config_libdir
  local native_wrapper_dir native_cc_wrapper native_cxx_wrapper

  cross_build_enabled || return 0

  host_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  build_triplet="$(build_deb_multiarch_triplet)"
  native_cc="$(_meson_native_tool "${host_path}" gcc cc)"
  native_cxx="$(_meson_native_tool "${host_path}" g++ c++)"
  native_ar="$(_meson_native_tool "${host_path}" ar)"
  native_strip="$(_meson_native_tool "${host_path}" strip)"
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
$(_meson_binaries_head "${native_cc}" "${native_cxx}" "${native_ar}" "${native_strip}")
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

# [path]: a native build's file with only the cached compilers; Meson ignores CMAKE_*_COMPILER_LAUNCHER, so this is how the cache reaches it (2026-10-28).
_ensure_meson_cache_native_file() {
  local launcher="" cc cxx path="${1:-${TMPDIR:-/tmp}/meson-native-cache.ini}"
  if command -v compiler_cache_launcher >/dev/null 2>&1; then launcher="$(compiler_cache_launcher 2>/dev/null || true)"; fi
  [ -n "${launcher}" ] || return 1
  cc="$(command -v "${CC:-cc}" 2>/dev/null || true)"
  cxx="$(command -v "${CXX:-c++}" 2>/dev/null || true)"
  [ -n "${cc}" ] && [ -n "${cxx}" ] || return 1
  _meson_binaries_head "${cc}" "${cxx}" "$(command -v ar)" "$(command -v strip)" > "${path}"
  export MESON_CACHE_NATIVE_FILE="${path}"
}

append_meson_native_flags() {
  local out_name="$1"
  local -n meson_native_flags_ref="${out_name}"

  if cross_build_enabled; then
    ensure_meson_native_file
    meson_native_flags_ref+=(--native-file "${MESON_NATIVE_FILE}")
    return 0
  fi
  _ensure_meson_cache_native_file || return 0
  meson_native_flags_ref+=(--native-file "${MESON_CACHE_NATIVE_FILE}")
}
