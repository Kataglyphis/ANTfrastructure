#!/usr/bin/env bash
# common.sh - shared helpers and configuration
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Values already in the environment (forwarded ARG/ENV) win over versions.env.
# shellcheck disable=SC1091
source "${_COMMON_SH_DIR}/load-versions-env.sh"
if [ -z "${_VERSIONS_ENV_LOADED:-}" ]; then
  load_versions_env "${_COMMON_SH_DIR}/versions.env"
  _VERSIONS_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/logging.sh" ] && source "${_COMMON_SH_DIR}/logging.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/platform.sh" ] && source "${_COMMON_SH_DIR}/platform.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/arch-mapping.sh" ] && source "${_COMMON_SH_DIR}/arch-mapping.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/ubuntu-mirror.sh" ] && source "${_COMMON_SH_DIR}/ubuntu-mirror.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/downloads.sh" ] && source "${_COMMON_SH_DIR}/downloads.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/parallelism.sh" ] && source "${_COMMON_SH_DIR}/parallelism.sh"
# Optional here, but a script using these helpers needs its RUN to mount guard-helpers.sh.
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/guard-helpers.sh" ] && source "${_COMMON_SH_DIR}/guard-helpers.sh"

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

# Required fallback: several media scripts call cross_build_is_active without sourcing cross-env.sh, its owner.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  if command -v cross_build_enabled >/dev/null 2>&1; then
    cross_build_is_active() { cross_build_enabled; }
  else
    # Normalize both sides: OCI names vs `uname -m` names made native arm64 hosts look cross.
    cross_build_is_active() {
      [ "${BUILD_MODE:-native}" = "cross" ] || return 1
      local _t _b
      _t="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || printf '%s' "${TARGET_ARCH:-${TARGETARCH:-}}")"
      _b="$(arch_normalize "${BUILDARCH:-$(uname -m)}" 2>/dev/null || printf '%s' "${BUILDARCH:-$(uname -m)}")"
      [ -n "${_t}" ] && [ "${_t}" != "${_b}" ]
    }
  fi
fi

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

APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-qq --no-install-recommends "${APT_OPTS[@]}")

SUDO=""
APT_UPDATED=""

# run_priv [--preserve-env[=VARS]]... <cmd>: drops the sudo-only flags when SUDO is empty, where they became the command.
run_priv() {
  local -a _preserve=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --preserve-env|--preserve-env=*) _preserve+=("$1"); shift ;;
      *) break ;;
    esac
  done
  if [ "$#" -eq 0 ]; then
    printf 'run_priv: no command given\n' >&2
    return 1
  fi
  if [ -n "${SUDO:-}" ]; then
    "${SUDO}" ${_preserve[@]+"${_preserve[@]}"} "$@"
  else
    "$@"
  fi
}

tool_version() {
  local cmd="$1"
  shift 2>/dev/null || true
  if command -v "$cmd" >/dev/null 2>&1; then
    "$cmd" "$@" || true
  fi
}

# Delegates to logging.sh's guard, which sets SUDO and SUDO_WRAP; inline fallback if it was not sourced.
require_sudo() {
  if command -v _ensure_sudo_wrapper >/dev/null 2>&1; then
    _ensure_sudo_wrapper "This script requires sudo or root."
    return
  fi
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
    SUDO="sudo"
    SUDO_WRAP="sudo"
  else
    SUDO=""
    SUDO_WRAP=""
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
    DISTRO="${UBUNTU_CODENAME:-${VERSION_CODENAME:-resolute}}"
  else
    DISTRO="jammy"
  fi
  export ARCH HOST_ARCH DISTRO
  log "Detected arch=${ARCH} host_arch=${HOST_ARCH} distro=${DISTRO}"
}

apt_update_once() {
  if [ -z "${APT_UPDATED}" ]; then
    run_priv apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  run_priv apt-get install -y "${APT_FLAGS[@]}" "$@"
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

# append_cross_idirafter <triplet>: the cross GCC (--sysroot=/) does not search the multiarch dirs apt installs into.
append_cross_idirafter() {
  local triplet="$1"
  [ -n "${triplet}" ] || return 1
  append_flag_if_missing CPPFLAGS "-idirafter /usr/include/${triplet}"
  append_flag_if_missing CPPFLAGS "-idirafter /usr/include"
  append_flag_if_missing CFLAGS  "-idirafter /usr/include/${triplet}"
  append_flag_if_missing CFLAGS  "-idirafter /usr/include"
  append_flag_if_missing CXXFLAGS "-idirafter /usr/include/${triplet}"
  append_flag_if_missing CXXFLAGS "-idirafter /usr/include"
}

llvm_release_version() {
  local version="${1:-${LLVM_WANTED:-${CLANG_WANTED:-23}}}"
  if [ -n "${LLVM_RELEASE:-}" ]; then
    printf '%s' "${LLVM_RELEASE}"
    return 0
  fi
  case "${version}" in
    23) printf '%s' "23.1.3" ;;
    22) printf '%s' "22.1.8" ;;
    *) printf '%s' "${version}.1.0" ;;
  esac
}

# Use this, not an inline ${LLVM_WANTED:-...} chain, so an LLVM bump touches one literal.
llvm_wanted_major() {
  if [ -n "${LLVM_WANTED:-}" ]; then
    printf '%s' "${LLVM_WANTED}"
    return 0
  fi
  if [ -n "${CLANG_WANTED:-}" ]; then
    printf '%s' "${CLANG_WANTED}"
    return 0
  fi
  printf '%s' "23"
}

llvm_git_tag() {
  printf '%s' "llvmorg-$(llvm_release_version "$@")"
}

# Fails at clone time, naming the tag and both SHAs; an empty LLVM_COMMIT tracks the tag.
llvm_assert_commit_pin() {
  local dir="$1" tag="$2" got
  [ -n "${LLVM_COMMIT:-}" ] || return 0
  got="$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)"
  [ "${got}" = "${LLVM_COMMIT}" ] || {
    printf 'ERROR: llvm-project %s resolved to %s, but LLVM_COMMIT pins %s\n' \
      "${tag}" "${got:-<unknown>}" "${LLVM_COMMIT}" >&2
    return 1
  }
  printf 'llvm-project %s verified against LLVM_COMMIT %s\n' "${tag}" "${LLVM_COMMIT}"
}

cross_wheel_platform_tag() {
  if ! command -v arch_linux_platform_tag_for >/dev/null 2>&1; then
    return 1
  fi
  arch_linux_platform_tag_for "$(cross_target_arch 2>/dev/null || true)"
}

# retag_directory_wheels <dir> <prefix|*> <platform_tag> [python_cmd...]: skips none-any and already-tagged wheels.
retag_directory_wheels() {
  local dist_dir="$1" glob_prefix="$2" platform_tag="$3"
  shift 3
  local -a python_cmd=("$@")
  [ "${#python_cmd[@]}" -gt 0 ] || python_cmd=(python3)
  local wheel_path wheel_name

  shopt -s nullglob
  for wheel_path in "${dist_dir}"/${glob_prefix}-*.whl; do
    wheel_name="$(basename "${wheel_path}")"
    case "${wheel_name}" in
      *-none-any.whl|*"${platform_tag}"*.whl) continue ;;
    esac
    "${python_cmd[@]}" -m wheel tags --remove --platform-tag="${platform_tag}" "${wheel_path}" >/dev/null && \
      info "Retagged for ${platform_tag}: ${wheel_name}" || \
      warn "Failed to retag ${wheel_name} for ${platform_tag}"
  done
  shopt -u nullglob
}

# A failed parallel build retries -j1 --verbose, for a readable error.
run_cmake_build_with_fallback() {
  local build_dir="$1" jobs="${2:-$(nproc)}"
  cmake --build "${build_dir}" -j"${jobs}" || {
    warn "Parallel build failed, trying single-threaded..."
    cmake --build "${build_dir}" -j1 --verbose
  }
}

# Installs ccache and exports CCACHE_DIR; callers wire the compiler themselves.
ensure_ccache_env() {
  if ! command -v ccache >/dev/null 2>&1; then
    warn "ccache not found, installing..."
    apt_install ccache
  fi
  CCACHE_DIR="${CCACHE_DIR:-${HOME}/.cache/ccache}"
  mkdir -p "${CCACHE_DIR}"
  export CCACHE_DIR
  info "Using ccache with CCACHE_DIR=${CCACHE_DIR}"
}

# Non-zero when sccache is unusable, so callers fall back to ccache; a dead server fails compiles, so it must answer.
ensure_sccache_env() {
  command -v sccache >/dev/null 2>&1 || {
    warn "sccache not found — caller should fall back to ccache"
    return 1
  }
  SCCACHE_DIR="${SCCACHE_DIR:-/var/cache/sccache}"
  mkdir -p "${SCCACHE_DIR}" 2>/dev/null || true
  export SCCACHE_DIR
  # A server that idles out mid-build is one of the recorded failure shapes.
  export SCCACHE_IDLE_TIMEOUT="${SCCACHE_IDLE_TIMEOUT:-0}"

  # A socket in the container's own /tmp keeps each server private; a shared TCP port reaches another container's.
  if [ -z "${SCCACHE_SERVER_UDS:-}" ] && [ -z "${SCCACHE_SERVER_PORT:-}" ]; then
    _scv="$(sccache --version 2>/dev/null | awk '{print $2}')"
    _scv_maj="${_scv%%.*}"; _scv_rest="${_scv#*.}"; _scv_min="${_scv_rest%%.*}"
    if [ "${_scv_maj:-0}" -ge 1 ] 2>/dev/null || [ "${_scv_min:-0}" -ge 14 ] 2>/dev/null; then
      export SCCACHE_SERVER_UDS="/tmp/sccache-$(id -u).sock"
    else
      _scp_off="$(printf '%s' "${HOSTNAME:-$$}" | cksum | awk '{print $1 % 20000}')"
      export SCCACHE_SERVER_PORT="$(( 20000 + _scp_off ))"
    fi
  fi
  # Direct mode re-reads inputs that CMake TryCompile already deleted: docs/build-cache-tiers.md#the-rules-as-agentsmd-carried-them-with-their-reasons
  export SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"
  export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}"
  sccache --start-server >/dev/null 2>&1 || true
  if ! sccache --show-stats >/dev/null 2>&1; then
    warn "sccache server did not answer — caller should fall back to ccache"
    return 1
  fi
  info "Using sccache with SCCACHE_DIR=${SCCACHE_DIR} (cap ${SCCACHE_CACHE_SIZE:-unset}) [server=${SCCACHE_SERVER_UDS:-tcp:${SCCACHE_SERVER_PORT:-4226}}]"
  return 0
}


# Echoes sccache, else ccache, for CC/CXX; stdout is the value, so helpers log to stderr (info() writes to fd 1).
compiler_cache_launcher() {
  if [ "${USE_SCCACHE:-1}" != "0" ] && ensure_sccache_env >&2; then
    # The guarded launcher survives sccache's own fatal errors; bare sccache where it is not mounted.
    for _scl in "${_COMMON_SH_DIR}/sccache-launcher.sh" /opt/scripts/core/sccache-launcher.sh; do
      if [ -x "${_scl}" ]; then
        printf '%s' "${_scl}"
        return 0
      fi
    done
    printf '%s' sccache
    return 0
  fi
  if ensure_ccache_env >&2 2>/dev/null && command -v ccache >/dev/null 2>&1; then
    warn "falling back to ccache for this stage"
    printf '%s' ccache
    return 0
  fi
  warn "no usable compiler cache (neither sccache nor ccache) — building uncached"
  return 1
}

# Call in the compiling shell: docs/build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run
compiler_cache_launcher_env() {
  if [ "${USE_SCCACHE:-1}" != "0" ]; then
    ensure_sccache_env >&2 || true
  fi
  return 0
}

# alt_install_and_set <name> <link> <path> [priority] [--candidate p]... [--slave l n p]...
alt_install_and_set() {
  local name="$1" link="$2" path="$3"
  local priority=100
  shift 3
  # Optional positional priority (present iff the next token is not an option).
  if [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; then
    priority="$1"
    shift
  fi

  local -a candidates=("${path}")
  local -a slave_args=()
  local candidate_search=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --candidate)
        candidate_search=1
        candidates+=("${2:-}")
        shift 2
        ;;
      --slave)
        slave_args+=(--slave "${2:-}" "${3:-}" "${4:-}")
        shift 4
        ;;
      *)
        shift
        ;;
    esac
  done

  # Resolve the binary to register: first executable candidate.
  local resolved="" c
  for c in "${candidates[@]}"; do
    [ -n "${c}" ] || continue
    if [ -x "${c}" ]; then
      resolved="${c}"
      break
    fi
  done
  if [ -z "${resolved}" ]; then
    if [ "${candidate_search}" -eq 1 ]; then
      # A candidate search was requested but nothing exists — nothing to do.
      return 0
    fi
    # No search requested: preserve the original verbatim-register behavior.
    resolved="${path}"
  fi

  local -a install_args=(--install "${link}" "${name}" "${resolved}" "${priority}")
  [ "${#slave_args[@]}" -eq 0 ] || install_args+=("${slave_args[@]}")

  run_priv update-alternatives "${install_args[@]}"
  run_priv update-alternatives --set "${name}" "${resolved}" || true
}

# generate_pkgconfig_file <path> <name> <desc> <version> <prefix> [libs] [cflags] [requires] [libs_private]
generate_pkgconfig_file() {
  local pc_path="$1" name="$2" desc="$3" ver="$4" prefix="$5"
  local libs cflags requires libs_private
  # Not `${6:--L\${libdir}}`: that expansion eats the closing brace and writes a stray `}` into the .pc.
  libs="${6:-}"
  [ -n "${libs}" ] || libs='-L${libdir}'
  cflags="${7:-}"
  [ -n "${cflags}" ] || cflags='-I${includedir}'
  requires="${8:-}"
  libs_private="${9:-}"
  local pc_dir
  pc_dir="$(dirname "${pc_path}")"
  mkdir -p "${pc_dir}"

  local req_line=""
  [ -n "${requires}" ] && req_line="Requires: ${requires}"
  local libs_private_line=""
  [ -n "${libs_private}" ] && libs_private_line="Libs.private: ${libs_private}"

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
${libs_private_line}
Cflags: ${cflags}
EOF
}

# python_module_include <python_bin> <module>: the module's get_include(), or empty on any failure.
python_module_include() {
  local py="$1" module="$2"
  [ -n "${py}" ] || return 0
  "${py}" -c "import ${module}; print(${module}.get_include())" 2>/dev/null || true
}

# verify_python_import <module> [version_expr]; PYTHON_IMPORT_PYTHON overrides the interpreter.
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
