#!/usr/bin/env bash
# common.sh - shared helpers and configuration
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source canonical version defaults (single source of truth).
# Variables already set in the environment take precedence over versions.env.
if [ -z "${_VERSIONS_ENV_LOADED:-}" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  [ -f "${_COMMON_SH_DIR}/versions.env" ] && source "${_COMMON_SH_DIR}/versions.env"
  set +a
  _VERSIONS_ENV_LOADED=1
fi

# Side-effect free helpers
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/logging.sh" ] && source "${_COMMON_SH_DIR}/logging.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/platform.sh" ] && source "${_COMMON_SH_DIR}/platform.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/ubuntu-mirror.sh" ] && source "${_COMMON_SH_DIR}/ubuntu-mirror.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/downloads.sh" ] && source "${_COMMON_SH_DIR}/downloads.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/parallelism.sh" ] && source "${_COMMON_SH_DIR}/parallelism.sh"

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

# Provide cross_build_is_active when cross-env.sh hasn't been sourced.
# The real definition in cross-env.sh checks BUILD_MODE=cross AND target arch != build arch.
# This fallback approximates that when cross_build_enabled is unavailable.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  if command -v cross_build_enabled >/dev/null 2>&1; then
    cross_build_is_active() { cross_build_enabled; }
  else
    cross_build_is_active() {
      [ "${BUILD_MODE:-native}" = "cross" ] && \
      [ "${TARGET_ARCH:-${TARGETARCH:-}}" != "${BUILDARCH:-$(uname -m)}" ]
    }
  fi
fi

# Derived defaults (use the canonical values from versions.env as fallbacks)
if [ -z "${LLVM_WANTED:-}" ]; then
  LLVM_WANTED="${LLVM_RELEASE}"
  LLVM_WANTED="$(version_major "${LLVM_WANTED}")"
fi

if [ -z "${CLANG_WANTED:-}" ]; then
  CLANG_WANTED="${LLVM_WANTED}"
fi

if [ -z "${GCC_WANTED:-}" ]; then
  GCC_WANTED="${GCC_VERSION}"
  GCC_WANTED="$(version_major "${GCC_WANTED}")"
fi

if [ -z "${PYTHON_MAJOR_MINOR:-}" ] && [ -n "${PYTHON_VERSION:-}" ]; then
  PYTHON_MAJOR_MINOR="$(version_major_minor "${PYTHON_VERSION}")"
fi

# ---------------------------------------------------------------------------
# ensure_target_arch
#
# Normalizes TARGET_ARCH from TARGETARCH when TARGET_ARCH is unset.
# Print the resolved value and export it.
# ---------------------------------------------------------------------------
ensure_target_arch() {
  TARGET_ARCH="$(canonical_target_arch "${TARGET_ARCH:-}")"
  export TARGET_ARCH
  printf '%s\n' "TARGET_ARCH=${TARGET_ARCH}"
}

APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-qq --no-install-recommends "${APT_OPTS[@]}")

SUDO=""
APT_UPDATED=""

tool_version() {
  local cmd="$1"
  shift 2>/dev/null || true
  if command -v "$cmd" >/dev/null 2>&1; then
    "$cmd" "$@" || true
  fi
}

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
    SUDO="sudo"
  else
    SUDO=""
  fi
}

detect_system() {
  local target_arch build_arch
  target_arch="$(arch_oci)"
  build_arch="$(build_arch_oci)"
  ARCH="$(arch_uname_name_for "${target_arch}")"
  HOST_ARCH="$(arch_uname_name_for "${build_arch}")"

  if command -v lsb_release >/dev/null 2>&1; then
    DISTRO="$(lsb_release -cs)"
  elif [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${UBUNTU_CODENAME:-${VERSION_CODENAME:-plucky}}"
  else
    DISTRO="jammy"
  fi
  export ARCH HOST_ARCH DISTRO
  log "Detected arch=${ARCH} host_arch=${HOST_ARCH} distro=${DISTRO}"
}

apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  $SUDO apt-get install -y "${APT_FLAGS[@]}" "$@"
}

apt_has_package() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_install_available() {
  local pkg
  local -a pkgs=()

  for pkg in "$@"; do
    if apt_has_package "$pkg"; then
      pkgs+=("$pkg")
    else
      log "Skipping missing package: ${pkg}"
    fi
  done

  if [ "${#pkgs[@]}" -gt 0 ]; then
    apt_install "${pkgs[@]}"
  fi
}

append_flag_if_missing() {
  local var_name="$1"
  local flag="$2"
  local current="${!var_name:-}"

  case " ${current} " in
    *" ${flag} "*) return 0 ;;
  esac

  export "${var_name}=${current:+${current} }${flag}"
}

shell_quote_args() {
  local quoted=""
  local arg
  for arg in "$@"; do
    quoted+="${quoted:+ }$(printf '%q' "${arg}")"
  done
  printf '%s' "${quoted}"
}

llvm_release_version() {
  local version="${1:-${LLVM_WANTED:-${CLANG_WANTED:-22}}}"
  if [ -n "${LLVM_RELEASE:-}" ]; then
    printf '%s' "${LLVM_RELEASE}"
    return 0
  fi
  case "${version}" in
    22) printf '%s' "22.1.8" ;;
    *) printf '%s' "${version}.1.0" ;;
  esac
}

# Single source of truth for the "wanted" LLVM major. Use instead of the
# ${LLVM_WANTED:-${CLANG_WANTED:-22}} fallback chain so a future LLVM bump
# (versions.env LLVM_RELEASE) only needs to update common.sh's literal above
# (the `22` literal there is loaded into LLVM_WANTED at module-load time via
# the block above this function).
llvm_wanted_major() {
  if [ -n "${LLVM_WANTED:-}" ]; then
    printf '%s' "${LLVM_WANTED}"
    return 0
  fi
  if [ -n "${CLANG_WANTED:-}" ]; then
    printf '%s' "${CLANG_WANTED}"
    return 0
  fi
  printf '%s' "22"
}

llvm_git_tag() {
  printf '%s' "llvmorg-$(llvm_release_version "$@")"
}

cross_wheel_platform_tag() {
  if ! command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
    return 1
  fi
  arch_linux_platform_tag_for "$(cross_target_arch 2>/dev/null || true)"
}

# ── cmake build with fallback ─────────────────────────────────────────────────
# Run cmake --build with parallel jobs; on failure, retry single-threaded with
# --verbose for diagnostics.  Patterns from build-litert.sh and build-opencv.sh.
#
# Usage: run_cmake_build_with_fallback <build_dir> <jobs>
run_cmake_build_with_fallback() {
  local build_dir="$1" jobs="${2:-$(nproc)}"
  cmake --build "${build_dir}" -j"${jobs}" || {
    warn "Parallel build failed, trying single-threaded..."
    cmake --build "${build_dir}" -j1 --verbose
  }
}

# ── pkg-config file generation ────────────────────────────────────────────────
# Generate a standard .pc file.  DRYs the identical heredoc pattern found in
# build-litert.sh and onnxruntime/runtime/31-generate-pkgconfig-native.sh.
#
# Usage: generate_pkgconfig_file <path> <name> <description> <version> <prefix> [libs] [cflags] [requires]
generate_pkgconfig_file() {
  local pc_path="$1" name="$2" desc="$3" ver="$4" prefix="$5"
  local libs cflags requires
  # NOTE: do NOT use `${6:--L\${libdir}}` here — bash's expansion of `:-`
  # defaults eats the trailing `}` of `${libdir}` and emits a stray literal
  # `}` into the .pc file (the root cause of the LiteRT
  # `tensorflow-lite.pc` trailing-brace bug, worked around in
  # build-gstreamer-monorepo.sh for years).
  libs="${6:-}"
  [ -n "${libs}" ] || libs='-L${libdir}'
  cflags="${7:-}"
  [ -n "${cflags}" ] || cflags='-I${includedir}'
  requires="${8:-}"
  local pc_dir
  pc_dir="$(dirname "${pc_path}")"
  mkdir -p "${pc_dir}"

  local req_line=""
  [ -n "${requires}" ] && req_line="Requires: ${requires}"

  cat >"${pc_path}" <<EOF
prefix=${prefix}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
${req_line}
Name: ${name}
Description: ${desc}
Version: ${ver}
Libs: ${libs}
Cflags: ${cflags}
EOF
}

# ── Python import verification ────────────────────────────────────────────────
# Verify a Python module can be imported.  Set PYTHON_IMPORT_PYTHON to override
# the interpreter (default: python3 or python).
#
# Usage: verify_python_import <module_name> [version_check_expr]
verify_python_import() {
  local module="$1" check="${2:-}"
  local py="${PYTHON_IMPORT_PYTHON:-}"
  [ -z "${py}" ] && py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null)"
  if [ -z "${py}" ]; then
    warn "No Python interpreter found; skipping import check for ${module}"
    return 1
  fi
  if [ -n "${check}" ]; then
    "${py}" -c "import ${module}; print(${check})" && return 0
  else
    "${py}" -c "import ${module}; print(${module}.__version__)" 2>/dev/null && return 0
    "${py}" -c "import ${module}; print('imported')" && return 0
  fi
  warn "Failed to import Python module: ${module}"
  return 1
}
