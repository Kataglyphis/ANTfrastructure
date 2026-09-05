#!/usr/bin/env bash
# common.sh - shared helpers and configuration
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load canonical version defaults (single source of truth). Variables already
# set in the environment (e.g. Dockerfile ARG/ENV values forwarded by the
# orchestrator) take precedence over versions.env — see load-versions-env.sh.
# shellcheck disable=SC1091
source "${_COMMON_SH_DIR}/load-versions-env.sh"
if [ -z "${_VERSIONS_ENV_LOADED:-}" ]; then
  load_versions_env "${_COMMON_SH_DIR}/versions.env"
  _VERSIONS_ENV_LOADED=1
fi

# Side-effect free helpers
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
# Named guard helpers (first_match/probe/source_vendor/csv_each). Guarded like
# the rest: skips cleanly if guard-helpers.sh is not co-mounted, so common.sh
# never breaks — but any script that MIGRATED to these helpers needs its RUN to
# mount guard-helpers.sh (added to the per-file-common.sh RUNs alongside this).
# shellcheck disable=SC1090,SC1091
[ -f "${_COMMON_SH_DIR}/guard-helpers.sh" ] && source "${_COMMON_SH_DIR}/guard-helpers.sh"

export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC

# Provide cross_build_is_active when cross-env.sh hasn't been sourced.
# The CANONICAL definition lives in cross-env.sh; this fallback is required
# because several scripts source common.sh WITHOUT cross-env.sh and still call
# cross_build_is_active (e.g. 03-media build-litert.sh, build-opencv.sh,
# build-ffmpeg.sh, build-libcamera.sh, setup-gstreamer.sh, pre-setup.sh,
# onnxruntime 30-build-native*.sh). Do NOT remove it.
# The real definition in cross-env.sh checks BUILD_MODE=cross AND target arch != build arch.
# This fallback approximates that when cross_build_enabled is unavailable.
if ! command -v cross_build_is_active >/dev/null 2>&1; then
  if command -v cross_build_enabled >/dev/null 2>&1; then
    cross_build_is_active() { cross_build_enabled; }
  else
    # NORMALIZE both sides (platform.sh is sourced above): TARGET_ARCH is
    # usually an OCI name (amd64/arm64) while `uname -m` yields machine names
    # (x86_64/aarch64) — the raw comparison reported "cross active" on every
    # NATIVE arm64 host. Same fix smoke-common.sh documented; this copy (and
    # its two clones, now delegating here) had drifted without it.
    cross_build_is_active() {
      [ "${BUILD_MODE:-native}" = "cross" ] || return 1
      local _t _b
      _t="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || printf '%s' "${TARGET_ARCH:-${TARGETARCH:-}}")"
      _b="$(arch_normalize "${BUILDARCH:-$(uname -m)}" 2>/dev/null || printf '%s' "${BUILDARCH:-$(uname -m)}")"
      [ -n "${_t}" ] && [ "${_t}" != "${_b}" ]
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

APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-qq --no-install-recommends "${APT_OPTS[@]}")

SUDO=""
APT_UPDATED=""

# ── run_priv — the safe replacement for the `${SUDO} cmd …` prefix idiom ──────
# Usage: run_priv [--preserve-env[=VARS]]... <cmd> [args...]
#
# Runs <cmd> through ${SUDO} when a real sudo is in play, and DIRECTLY when SUDO
# is empty (already root — which is every foreign-arch cross container). The
# leading --preserve-env* flags are sudo-ONLY and are dropped on the direct
# path, because there is no sudo there to strip the environment in the first
# place.
#
# That drop is the whole point. The idiom this replaces expanded the SUDO
# variable inline as a command prefix and put a sudo-only flag straight after
# it; with SUDO empty the shell then took the FLAG as the command and exited
# 127 — bug 7e6d627, which hid behind the sdk cache until a no-cache run.
# test-invocation-lints.sh bans that spelling tree-wide (the ban is on CODE, not
# prose — hence the deliberately flag-free wording here), and run_priv is what
# the banned sites migrate to. The remaining ~32 inline SUDO-prefix call sites
# in 02-toolchain/vulkan.sh are the rebuild-gated half of that migration.
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

# Delegates to the canonical sudo-guard core in logging.sh (sourced above),
# which sets BOTH SUDO and SUDO_WRAP. Preserves this script's original die
# message. A defensive inline fallback covers the (unexpected) case where
# logging.sh was not sourced.
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

# Append cross-compilation include-path fallback flags to CPPFLAGS, CFLAGS,
# and CXXFLAGS. The custom cross-GCC with --sysroot=/ does NOT search the
# Debian multiarch dirs where apt installs :<arch> dev headers, so cross
# builds need -idirafter for both the triplet-specific and generic /usr/include
# paths. Replaces the 6-line inline pattern duplicated across gstreamer,
# libcamera, opencv, litert, python, and torch build scripts.
#
# Usage: append_cross_idirafter <triplet>
# Example: append_cross_idirafter aarch64-linux-gnu
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
    23) printf '%s' "23.1.0" ;;
    22) printf '%s' "22.1.8" ;;
    *) printf '%s' "${version}.1.0" ;;
  esac
}

# Single source of truth for the "wanted" LLVM major. Use instead of the
# ${LLVM_WANTED:-${CLANG_WANTED:-23}} fallback chain so a future LLVM bump
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
  printf '%s' "23"
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

# ── directory wheel retag ─────────────────────────────────────────────────────
# Retag every matching wheel in a directory to <platform_tag> via
# `python -m wheel tags --remove --platform-tag=...`. Canonical implementation
# (backlog D2) replacing the three drifted copies in 03-media/runtime/
# repair-wheels.sh, 05-frameworks/tvm-python.sh and 05-frameworks/torch/
# build-app-wheelhouse.sh. Guarded by tests/test-arch-mapping.sh (T4).
#
# Always skipped: pure-python *-none-any.whl (a platform retag would be wrong)
# and wheels already carrying <platform_tag> (rerun-safe: the media wheelhouse
# retags in place). A per-wheel retag failure warns and continues — all three
# former copies tolerated it.
#
# Usage: retag_directory_wheels <dist_dir> <glob_prefix|*> <platform_tag> [python_cmd...]
#   glob_prefix  wheel name prefix, matched as <prefix>-*.whl ('*' = all wheels)
#   python_cmd   launcher for `-m wheel` (default: python3); may be multi-word,
#                e.g. `uv run python`, or a venv/host python path
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

# ── ccache environment setup ──────────────────────────────────────────────────
# Ensure ccache is installed and CCACHE_DIR is created + exported. Shared
# prologue for the from-source toolchain builders (build-gcc.sh, build-clang.sh).
# Callers keep their own compiler wiring afterwards: build-gcc.sh exports
# CC="ccache gcc"/CXX="ccache g++"; build-clang.sh passes
# -DCMAKE_*_COMPILER_LAUNCHER=ccache.
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

# sccache counterpart of ensure_ccache_env (2026-08-26, the ccache->sccache
# switch). Returns NON-ZERO when sccache cannot be used, so every caller can
# fall back to ccache instead of losing caching silently -- the failure mode
# this repo keeps paying for.
#
# The server matters here in a way ccache has no analogue for: sccache is a
# client/daemon pair, and a dead server is a HARD compile failure, not a miss.
# It is started explicitly and then PROVEN to answer, rather than assumed.
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

  # ── ONE SERVER PER CONTAINER, BY CONSTRUCTION ────────────────────────────
  # sccache is a client/SERVER pair and the compiler runs in the SERVER's
  # context. That is the structural difference from ccache, and every failure
  # this migration hit comes out of it. The server is found by ADDRESS, and the
  # default address is a fixed TCP port (4226) -- which is not container-local:
  # BuildKit builds the media stages concurrently in containers that share a
  # network namespace under rootless buildkitd, so a client can reach ANOTHER
  # container's server. That server accepts the job ("Server sent
  # CompileStarted") and then cannot find the source, because the path exists
  # only in the caller:  No such file or directory (os error 2).
  #
  # Hashing the port per container narrows the odds but does not remove them.
  # A UNIX SOCKET does: its address is a filesystem path, and /tmp is part of
  # the container's own filesystem (only bind and cache mounts are shared), so
  # the address space is private BY CONSTRUCTION rather than by luck.
  # SCCACHE_SERVER_UDS needs sccache >= 0.14 (versions.env pins 0.17.0); the
  # port hash stays as the fallback for the distro 0.13 build.
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
  # PREPROCESSOR CACHE MODE OFF (2026-08-26, after it broke two builds).
  # In that mode sccache re-reads the INPUT FILE to store the cache entry AFTER
  # the compile. CMake's TryCompile probes create a scratch dir, compile in it,
  # and DELETE it immediately -- so the re-read hits ENOENT and sccache treats
  # it as FATAL:
  #   sccache: error: while hashing the input file
  #     '.../CMakeFiles/CMakeScratch/TryCompile-XXXX/testCCompiler.c'
  #   caused by: No such file or directory (os error 2)
  # It killed OpenCV's compiler test, then onnxruntime's, three times running.
  # The mode is OFF by default in sccache; enabling it was our change, so this
  # reverts to upstream behaviour rather than working around a bug. Cost is hit
  # rate (sccache preprocesses instead of hashing inputs directly), not
  # correctness. Set SCCACHE_DIRECT=true to re-enable once the ephemeral-dir
  # interaction is understood.
  export SCCACHE_DIRECT="${SCCACHE_DIRECT:-false}"
  export SCCACHE_ERROR_LOG="${SCCACHE_ERROR_LOG:-/tmp/sccache.log}"
  sccache --start-server >/dev/null 2>&1 || true
  if ! sccache --show-stats >/dev/null 2>&1; then
    warn "sccache server did not answer — caller should fall back to ccache"
    return 1
  fi
  info "Using sccache with SCCACHE_DIR=${SCCACHE_DIR} (cap ${SCCACHE_CACHE_SIZE:-unset})"
  return 0
}


# Name of the compiler-cache launcher to prefix onto CC/CXX, echoed on stdout.
# Prefers sccache (the 2026-08-26 decision) and falls back to ccache when
# sccache is absent or its server will not answer. Returns non-zero when
# neither is usable, so callers can build uncached rather than break.
# CRITICAL: this function's STDOUT is its return value -- callers capture it
# with $(...) and put the result straight into CC/CXX. Every helper it calls
# must therefore be redirected to stderr, because info() writes to fd 1
# (logging.sh:77) while warn() writes to fd 2.
#
# This bit for real on 2026-08-26: ensure_sccache_env's info() line leaked into
# the substitution and GCC was configured with
#   CC="[INFO] Using sccache with SCCACHE_DIR=... (cap 30G)sccache gcc"
# which surfaced as the maximally unhelpful "configure: error: C compiler
# cannot create executables". Keep the >&2 redirects.
compiler_cache_launcher() {
  if [ "${USE_SCCACHE:-1}" != "0" ] && ensure_sccache_env >&2; then
    # Prefer the guarded launcher when it is mounted: it runs sccache exactly
    # as before, but survives sccache's OWN fatal errors (CMake TryCompile
    # deletes its scratch dir, sccache then spawns with a cwd that no longer
    # exists -> ENOENT -> build break). See sccache-launcher.sh for the proof.
    # Bare `sccache` remains the answer where the helper is not mounted, so
    # nothing regresses in stages that do not carry 01-core.
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

# Establish the compiler-cache environment in the shell that will run the
# COMPILES. Every caller resolves the launcher with $( ), and a subshell cannot
# export to its parent, so the sccache server address set inside that
# substitution never reaches ninja/cmake. Total and idempotent; stdout is kept
# clean because callers capture the launcher next.
# docs/build-cache-tiers.md#the-server-address-must-be-exported-where-the-compiles-run
compiler_cache_launcher_env() {
  if [ "${USE_SCCACHE:-1}" != "0" ]; then
    ensure_sccache_env >&2 || true
  fi
  return 0
}

# Why apt calls retry and how the mirror fallback works:
# docs/cross-build-verification.md
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

# ── pkg-config file generation ────────────────────────────────────────────────
# Generate a standard .pc file.  DRYs the identical heredoc pattern found in
# build-litert.sh and onnxruntime/runtime/31-generate-pkgconfig-native.sh.
#
# Usage: generate_pkgconfig_file <path> <name> <description> <version> <prefix> [libs] [cflags] [requires] [libs_private]
generate_pkgconfig_file() {
  local pc_path="$1" name="$2" desc="$3" ver="$4" prefix="$5"
  local libs cflags requires libs_private
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

# Echo the C-header include dir a Python module exposes via get_include()
# (numpy, pybind11, ...); empty string on any failure (missing interpreter or
# module, no get_include). Consolidates the
# `$PY -c 'import M; print(M.get_include())'` pattern the cross media builds use
# to feed target include dirs into BUILD_FLAGS / cmake.
#
# Usage: python_module_include <python_bin> <module>
python_module_include() {
  local py="$1" module="$2"
  [ -n "${py}" ] || return 0
  "${py}" -c "import ${module}; print(${module}.get_include())" 2>/dev/null || true
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
