#!/usr/bin/env bash
# cross-env.sh - shared helpers for amd64-hosted target builds
[ -n "${_CROSS_ENV_SH_LOADED:-}" ] && return 0
_CROSS_ENV_SH_LOADED=1

_CROSS_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CROSS_ENV_APT_UPDATED="${_CROSS_ENV_APT_UPDATED:-0}"

# shellcheck disable=SC1090,SC1091
[ -f "${_CROSS_ENV_DIR}/platform.sh" ] && source "${_CROSS_ENV_DIR}/platform.sh"
# shellcheck disable=SC1090,SC1091
[ -f "${_CROSS_ENV_DIR}/ubuntu-mirror.sh" ] && source "${_CROSS_ENV_DIR}/ubuntu-mirror.sh"

cross_foreign_arch_ports_mirror_url() {
  local archive_url explicit_ports_url

  # A1: dropped the dead `${UBUNTU_PORTS_MIRROR_URL:-}` inner fallback — that
  # (un-prefixed) name was never set anywhere and is undocumented (only the
  # FAST_ variant is a real operator knob), so the fallback always resolved empty.
  explicit_ports_url="${FAST_UBUNTU_PORTS_MIRROR_URL:-}"
  if ubuntu_mirror_is_truthy "${USE_FAST_UBUNTU_MIRROR:-false}"; then
    archive_url="${FAST_UBUNTU_MIRROR_URL:-$(ubuntu_default_archive_mirror_url)}"
    ubuntu_effective_ports_mirror_url "${archive_url}" "${explicit_ports_url}"
    return 0
  fi

  ubuntu_mirror_normalize_url "${explicit_ports_url:-$(ubuntu_default_ports_mirror_url)}"
}

cross_mode_requested() {
  [ "${BUILD_MODE:-native}" = "cross" ]
}

cross_target_is_foreign() {
  [ "$(build_arch_oci)" != "$(arch_oci)" ]
}

# NAMING: cross_build_is_active() is the CANONICAL public name for the
# cross-build guard — use it in new code. is_cross() and cross_build_enabled()
# are kept as compatibility aliases for the 60+ existing callers; do not add
# new callers of those names. All three share this single implementation body.

# All-purpose cross-build guard used by 60+ media/toolchain/framework scripts.
cross_build_is_active() {
  cross_mode_requested || return 1
  cross_target_is_foreign
}

# Compatibility aliases — delegate to the canonical implementation above.
is_cross() { cross_build_is_active; }
cross_build_enabled() { cross_build_is_active; }

cross_target_arch() {
  arch_oci
}

cross_build_arch() {
  build_arch_oci
}

cross_require_single_target_arch() {
  local raw
  raw="$(default_target_arch "${1:-}")"
  local scope="${2:-cross build}"
  local target_arch=""

  [ -n "${raw}" ] || {
    printf 'TARGET_ARCH is required for %s\n' "${scope}" >&2
    return 1
  }

  case "${raw}" in
    *,*)
      printf 'TARGET_ARCH must be a single architecture for %s: %s\n' "${scope}" "${raw}" >&2
      return 1
      ;;
  esac

  target_arch="$(canonical_target_arch "${raw}" 2>/dev/null || true)"
  case "${target_arch}" in
    amd64|arm64|386|riscv64)
      printf '%s' "${target_arch}"
      return 0
      ;;
  esac

  printf 'Unsupported TARGET_ARCH=%s\n' "${raw}" >&2
  return 1
}

cross_set_target_env() {
  local target_arch=""

  target_arch="$(cross_require_single_target_arch "$(default_target_arch "${1:-}")" "${2:-cross build}")" || return 1
  export TARGET_ARCH="${target_arch}"
  export TARGETARCH="${target_arch}"
  export TARGETPLATFORM="linux/${target_arch}"
}

prepare_cross_target_env() {
  local scope="${2:-cross build}"

  cross_set_target_env "$(default_target_arch "${1:-}")" "${scope}" || return 1
  if cross_build_enabled; then
    install_cross_bin_symlinks "${TARGET_ARCH}"
  fi
  setup_linux_cross_env
}

cross_effective_targets_raw() {
  cross_targets_effective_raw "$@"
}

# ── cross-target iteration ────────────────────────────────────────────────────
# Centralizes the "for each supported cross target" loop whose amd64|arm64|riscv64
# set is otherwise hardcoded in ~6 places.
#
# Contract:
#   for_each_cross_target <callback> [--include-amd64] [target_list]
#
#   * <callback>       required; invoked once per normalized target as
#                      `<callback> <target>`.
#   * --include-amd64  include amd64 in the iteration (default: amd64 is skipped,
#                      since it is normally the native build arch).
#   * [target_list]    CSV/space list to iterate; defaults to
#                      cross_targets_effective_raw (VERIFY_CROSS_TARGETS /
#                      CROSS_TARGETS / ARCH / TARGETARCH / TARGET_ARCH).
#
# The list is normalized via arch_list_csv_normalize, then each target is
# validated against the supported cross set (amd64|arm64|riscv64); anything else
# (e.g. 386) is logged and skipped. Returns 2 if no callback was given, 1 if the
# list normalizes to nothing valid, otherwise the callback's aggregated non-zero
# exit status (0 when every invocation succeeded).
for_each_cross_target() {
  local callback=""
  local target_list=""
  local include_amd64=0
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --include-amd64) include_amd64=1 ;;
      *)
        if [ -z "${callback}" ]; then
          callback="${arg}"
        else
          target_list="${arg}"
        fi
        ;;
    esac
  done

  [ -n "${callback}" ] || {
    printf 'for_each_cross_target: a callback is required\n' >&2
    return 2
  }

  [ -n "${target_list}" ] || target_list="$(cross_targets_effective_raw 2>/dev/null || true)"
  [ -n "${target_list}" ] || return 0

  local normalized
  normalized="$(arch_list_csv_normalize "${target_list}")" || {
    printf 'for_each_cross_target: no supported target in "%s"\n' "${target_list}" >&2
    return 1
  }

  local target rc=0
  # Split on commas via `IFS=',' read` (scoped to the builtin). This function is
  # sourced into scripts that set IFS=$'\n\t' (all 02/03 build scripts), where a
  # bare ${normalized//,/ } expansion does not split on spaces and the loop
  # would run once with the whole list as a single bogus target.
  local -a _fect_targets=()
  IFS=',' read -r -a _fect_targets <<< "${normalized}"
  for target in "${_fect_targets[@]}"; do
    case "${target}" in
      amd64)
        [ "${include_amd64}" -eq 1 ] || continue
        "${callback}" "${target}" || rc=$?
        ;;
      arm64|riscv64)
        "${callback}" "${target}" || rc=$?
        ;;
      *)
        printf 'for_each_cross_target: skipping unsupported target %s\n' "${target}" >&2
        ;;
    esac
  done
  return "${rc}"
}

cross_bin_dir() {
  printf '%s' "${CROSS_BIN_DIR:-/opt/cross-bin}"
}

# Directory holding BARE-named cross tools (gcc, cc, as, ld, ...). It is
# deliberately NOT on PATH: bare cross names shadowing host tools broke every
# host-side compile (e.g. the riscv64 host-protoc "Exec format error" bug).
# Consumers that genuinely need bare names (gcc -B lookups, rust cc-crate
# fallbacks) must prepend this directory themselves for that single scope:
#   bare="$(cross_bare_bin_path)" && do_thing -B"${bare}/"
# Echoes the path only if the directory exists; returns 1 otherwise.
cross_bare_bin_path() {
  local dir
  dir="$(cross_bin_dir)/bare"
  [ -d "${dir}" ] || return 1
  printf '%s' "${dir}"
}

cross_target_triplet_for_arch() {
  arch_deb_multiarch_triplet_for "$1"
}

cross_target_triplet() {
  cross_target_triplet_for_arch "$(cross_target_arch)"
}

cross_target_rust_triple() {
  rust_target_triple
}

cross_build_rust_triple() {
  case "$(cross_build_arch)" in
    amd64) printf '%s' "x86_64-unknown-linux-gnu" ;;
    arm64) printf '%s' "aarch64-unknown-linux-gnu" ;;
    386) printf '%s' "i686-unknown-linux-gnu" ;;
    riscv64) printf '%s' "riscv64gc-unknown-linux-gnu" ;;
    *) printf '%s' "" ;;
  esac
}

cross_target_cpu_family() {
  arch_cpu_family_for "$(cross_target_arch)"
}

cross_target_cpu() {
  arch_cpu_for "$(cross_target_arch)"
}

cross_target_upper_rust() {
  cross_target_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_build_upper_rust() {
  cross_build_rust_triple | tr '[:lower:]-' '[:upper:]_'
}

cross_target_lower_rust() {
  cross_target_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

cross_build_lower_rust() {
  cross_build_rust_triple | tr '[:upper:]-' '[:lower:]_'
}

# Wire the Rust *target* toolchain env for a cross cdylib/staticlib link. Without
# CARGO_TARGET_<triple>_LINKER cargo links target artifacts with the host
# cc/rust-lld and fails ("<obj> is incompatible with elf64-x86-64"). Point the
# target triple's linker + cc-rs compiler at the real cross gcc (which carries
# its own as/ld); the host CARGO_TARGET_<build>/HOST_CC stay untouched so
# proc-macros and build scripts keep using the native toolchain.
#
# Shared by setup-gstreamer.sh (prepare_host_cargo_toolchain_env) and
# install-rice-proto.sh; the monorepo reuses the former. Callers keep their own
# success/WARN logging so per-site log output is unchanged.
#
# Args: <rust_env> [rust_lower] [cc] [cxx]
#   rust_env   uppercased/underscored target triple (RISCV64GC_UNKNOWN_LINUX_GNU)
#   rust_lower lowercased/underscored triple for CC_<lower>/CXX_<lower> (optional)
#   cc         target C compiler (must be executable)
#   cxx        target C++ compiler (optional; exported as CXX_<lower> if executable)
# Returns 0 on success; 1 when rust_env or a usable cc is missing.
export_cargo_target_linker() {
  local rust_env="$1" rust_lower="${2:-}" cc="${3:-}" cxx="${4:-}"
  [ -n "${rust_env}" ] && [ -n "${cc}" ] && [ -x "${cc}" ] || return 1
  export "CARGO_TARGET_${rust_env}_LINKER=${cc}"
  [ -n "${rust_lower}" ] && export "CC_${rust_lower}=${cc}"
  [ -n "${rust_lower}" ] && [ -n "${cxx}" ] && [ -x "${cxx}" ] && export "CXX_${rust_lower}=${cxx}"
  return 0
}

install_cross_bin_symlinks() {
  local target_arch
  target_arch="$(default_target_arch "${1:-}")"
  local bin_dir="${2:-$(cross_bin_dir)}"

  target_arch="$(cross_require_single_target_arch "${target_arch}" "cross tool symlink setup")" || return 1
  local triplet
  triplet="$(cross_target_triplet_for_arch "${target_arch}")" || {
    printf 'Unsupported cross tool target: %s\n' "${target_arch}" >&2
    return 1
  }

  # Resolve all cross toolchain tools. Data-driven: each entry is "tool_name".
  # All resolve via resolve_cross_gcc_tool (any failure short-circuits).
  local -A tools=()
  local tool
  for tool in gcc g++ ar as ld nm ranlib strip objcopy; do
    tools["${tool}"]="$(resolve_cross_gcc_tool "${tool}" "${triplet}")" || return 1
  done

  # Layout contract (see cross_bare_bin_path):
  #   ${bin_dir}       — ONLY triplet-prefixed names; safe to put on PATH,
  #                      they can never shadow host cc/gcc/as/ld.
  #   ${bin_dir}/bare  — bare names for the few consumers that need them
  #                      (gcc -B, rust cc-crate); NEVER placed on PATH here.
  local bare_dir="${bin_dir}/bare"
  mkdir -p "${bin_dir}" "${bare_dir}"

  # Triplet-prefixed symlinks (safe to put on PATH).
  for tool in gcc g++ as ld ar nm ranlib strip objcopy; do
    ln -sf "${tools[${tool}]}" "${bin_dir}/${triplet}-${tool}"
  done

  # Bare-name symlinks (gcc-alias cc, g++-alias c++ — see cross_bare_bin_path
  # for the NEVER-on-PATH contract; consumers must explicitly opt in).
  local bare_aliases=(gcc g++ cc c++ as ld ar nm ranlib strip objcopy)
  local bare_alias_tool=(gcc  g++ gcc g++ as ld ar nm ranlib strip objcopy)
  local i
  for i in "${!bare_aliases[@]}"; do
    ln -sf "${tools[${bare_alias_tool[$i]}]}" "${bare_dir}/${bare_aliases[$i]}"
  done

  # Stale-layout cleanup: earlier revisions symlinked bare names directly in
  # ${bin_dir} (which sat on PATH — the systemic footgun). Remove any leftovers
  # so a rebuilt layer can never resurrect bare cross tools onto PATH.
  local stale
  for stale in gcc g++ cc c++ as ld ar nm ranlib strip objcopy clang clang++; do
    [ -L "${bin_dir}/${stale}" ] && rm -f "${bin_dir}/${stale}"
  done

  if command -v "clang-${target_arch}" >/dev/null 2>&1; then
    ln -sf "$(command -v "clang-${target_arch}")" "${bare_dir}/clang"
  fi
  if command -v "clang++-${target_arch}" >/dev/null 2>&1; then
    ln -sf "$(command -v "clang++-${target_arch}")" "${bare_dir}/clang++"
  fi
}

_cross_first_executable() {
  local candidate resolved

  for candidate in "$@"; do
    [ -n "${candidate}" ] || continue
    if [ -x "${candidate}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
    if resolved="$(command -v "${candidate}" 2>/dev/null || true)" && [ -n "${resolved}" ]; then
      printf '%s' "${resolved}"
      return 0
    fi
  done

  return 1
}

cross_target_qemu_runner_for_arch() {
  local target_arch="$1"
  local qemu_arch=""

  case "$(arch_normalize "${target_arch}")" in
    amd64) qemu_arch="x86_64" ;;
    arm64) qemu_arch="aarch64" ;;
    386) qemu_arch="i386" ;;
    riscv64) qemu_arch="riscv64" ;;
    *) return 1 ;;
  esac

  _cross_first_executable \
    "/usr/bin/qemu-${qemu_arch}-static" \
    "/usr/bin/qemu-${qemu_arch}" \
    "$(command -v "qemu-${qemu_arch}-static" 2>/dev/null || true)" \
    "$(command -v "qemu-${qemu_arch}" 2>/dev/null || true)"
}

cross_target_qemu_runner() {
  cross_target_qemu_runner_for_arch "$(cross_target_arch)"
}


# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-gcc.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-python.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-apt.sh"
# shellcheck disable=SC1091
source "${_CROSS_ENV_DIR}/cross-meson.sh"

# Private: resolve the core architecture identifiers (triplet, rust target, etc.).
# Populates the provided associative array with keys:
#   target_arch, build_arch, triplet, processor, rust_target, rust_env,
#   rust_env_lower, build_rust_lower, gcc_prefix, gcc_major, runtime_libdir
_cross_env_resolve_identifiers() {
  local -n _eri_out=$1

  _eri_out[target_arch]="$(cross_target_arch)"
  _eri_out[build_arch]="$(cross_build_arch)"
  _eri_out[triplet]="$(cross_target_triplet)"
  _eri_out[processor]="$(cmake_system_processor)"
  _eri_out[rust_target]="$(cross_target_rust_triple)"
  _eri_out[rust_env]="$(cross_target_upper_rust)"
  _eri_out[rust_env_lower]="$(cross_target_lower_rust)"
  _eri_out[build_rust_lower]="$(cross_build_lower_rust 2>/dev/null || true)"
  _eri_out[gcc_prefix]="$(gcc_toolchain_prefix)"
  _eri_out[gcc_major]="${GCC_WANTED:-${GCC_VERSION:-16.2.0}}"
  _eri_out[gcc_major]="$(version_major "${_eri_out[gcc_major]}")"
  _eri_out[runtime_libdir]="${_eri_out[gcc_prefix]}/lib/gcc/${_eri_out[triplet]}/${_eri_out[gcc_major]}"
}

# Private: resolve all cross-compiler tool paths for a target triplet.
# Populates the provided associative array with keys:
#   cc, cxx, ar, as, ld, nm, ranlib, strip, objcopy,
#   build_cc, build_cxx, build_ar, build_ranlib
_cross_env_resolve_tools() {
  local triplet="$1"
  local -n _ert_out=$2

  _ert_out[cc]="$(require_cross_gcc_tool gcc "${triplet}" 'cross compiler')" || return 1
  if ! _ert_out[cxx]="$(require_cross_gcc_tool g++ "${triplet}" 'cross compiler')"; then
    # Some cross-triplet g++ binaries may not be found by
    # resolve_cross_gcc_tool even though they exist. Derive from CC.
    if command -v derive_cxx_from_cc >/dev/null 2>&1; then
      _ert_out[cxx]="$(derive_cxx_from_cc "${_ert_out[cc]}")" || return 1
    else
      _cxx_fb="$(printf '%s' "${_ert_out[cc]}" | sed 's/-gcc$/-g++/')"
      [ -x "${_cxx_fb}" ] && _ert_out[cxx]="${_cxx_fb}" || return 1
    fi
  fi
  local _bt
  for _bt in ar as ld nm ranlib strip objcopy; do
    _ert_out[$_bt]="$(require_cross_gcc_tool "$_bt" "${triplet}" 'cross binutils tool')" || return 1
  done
  _ert_out[build_cc]="$(resolve_build_gcc_tool gcc 2>/dev/null || true)"
  _ert_out[build_cxx]="$(resolve_build_gcc_tool g++ 2>/dev/null || true)"
  _ert_out[build_ar]="$(resolve_build_gcc_tool ar 2>/dev/null || true)"
  _ert_out[build_ranlib]="$(resolve_build_gcc_tool ranlib 2>/dev/null || true)"
}

# Private: set up cross Python staging directories.
_cross_env_setup_python_staging() {
  local target_arch="$1"

  export PYTHON_CROSS_STAGE_ROOT="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}"
  local _active="${PYTHON_CROSS_ACTIVE_ROOT:-}"
  if [ -z "${_active}" ] || [ ! -d "${_active}/usr/local" ]; then
    local _stage="${PYTHON_CROSS_STAGE_ROOT:-/opt/python-cross}/${target_arch}"
    if [ -d "${_stage}/usr/local" ]; then
      PYTHON_CROSS_ACTIVE_ROOT="${_stage}"
    else
      PYTHON_CROSS_ACTIVE_ROOT="${PYTHON_CROSS_ACTIVE_ROOT:-/opt/python-target}"
    fi
  fi
  export PYTHON_CROSS_ACTIVE_ROOT
}

# Each _export_* helper consumes the resolved associative array and exports a
# single logical group. Together they form _cross_env_export_all.

_export_arch_vars() {
  local -n _eav=$1
  export TARGET_ARCH="${_eav[target_arch]}"
  export TARGETARCH="${_eav[target_arch]}"
  export TARGETPLATFORM="linux/${_eav[target_arch]}"
  export BUILDARCH="${_eav[build_arch]}"
  export BUILDPLATFORM="linux/${_eav[build_arch]}"
  export CROSS_TARGET_TRIPLET="${_eav[triplet]}"
  export CROSS_TARGET_PROCESSOR="${_eav[processor]}"
  export CROSS_RUST_TARGET="${_eav[rust_target]}"
}

_export_path() {
  # /opt/cross-bin holds ONLY triplet-prefixed tool names, so fronting PATH
  # with it is harmless to host-side compiles. Bare names live in
  # /opt/cross-bin/bare, which is intentionally NOT put on PATH — see
  # cross_bare_bin_path() for the opt-in contract.
  local dir
  dir="$(cross_bin_dir 2>/dev/null || true)"
  if [ -n "${dir}" ] && [ -d "${dir}" ]; then
    export PATH="${dir}:${PATH}"
  fi
}

_export_toolchain_vars() {
  local -n _etv=$1
  export CC="${_etv[cc]}" CXX="${_etv[cxx]}" AR="${_etv[ar]}" AS="${_etv[as]}" \
    LD="${_etv[ld]}" NM="${_etv[nm]}" RANLIB="${_etv[ranlib]}" \
    STRIP="${_etv[strip]}" OBJCOPY="${_etv[objcopy]}"
  export "CC_${_etv[rust_env_lower]}=${CC}"
  export "CXX_${_etv[rust_env_lower]}=${CXX}"
  export "AR_${_etv[rust_env_lower]}=${AR}"
  export "RANLIB_${_etv[rust_env_lower]}=${RANLIB}"
  if [ -n "${_etv[build_rust_lower]}" ]; then
    [ -n "${_etv[build_cc]}" ] && export "CC_${_etv[build_rust_lower]}=${_etv[build_cc]}"
    [ -n "${_etv[build_cxx]}" ] && export "CXX_${_etv[build_rust_lower]}=${_etv[build_cxx]}"
    [ -n "${_etv[build_ar]}" ] && export "AR_${_etv[build_rust_lower]}=${_etv[build_ar]}"
    [ -n "${_etv[build_ranlib]}" ] && export "RANLIB_${_etv[build_rust_lower]}=${_etv[build_ranlib]}"
  fi

  if command -v "clang-${_etv[target_arch]}" >/dev/null 2>&1; then
    export CLANG="clang-${_etv[target_arch]}"
  fi
  if command -v "clang++-${_etv[target_arch]}" >/dev/null 2>&1; then
    export CLANGXX="clang++-${_etv[target_arch]}"
  fi
}

_export_pkg_config() {
  local -n _epc=$1
  export PKG_CONFIG_ALLOW_CROSS=1
  export PKG_CONFIG_SYSROOT_DIR="${PKG_CONFIG_SYSROOT_DIR:-/}"
  PKG_CONFIG_LIBDIR="$(cross_pkg_config_libdir "${_epc[triplet]}")"
  export PKG_CONFIG_LIBDIR
}

_export_library_path() {
  local -n _elp=$1
  local target_link_path="" dir
  for dir in \
    "${_elp[runtime_libdir]}" \
    "${_elp[gcc_prefix]}/${_elp[triplet]}/lib" \
    "/usr/lib/${_elp[triplet]}" \
    "/lib/${_elp[triplet]}" \
    "/usr/${_elp[triplet]}/lib"; do
    [ -d "${dir}" ] || continue
    target_link_path="${target_link_path:+${target_link_path}:}${dir}"
  done
  if [ -n "${target_link_path}" ]; then
    export LIBRARY_PATH="${target_link_path}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  fi
}

_export_cmake_vars() {
  local -n _ecmv=$1
  export CMAKE_SYSTEM_NAME=Linux
  export CMAKE_SYSTEM_PROCESSOR="${_ecmv[processor]}"
  export CMAKE_SYSROOT="${CMAKE_SYSROOT:-/}"
  export CMAKE_C_COMPILER="${CC}"
  export CMAKE_CXX_COMPILER="${CXX}"
  export CMAKE_ASM_COMPILER="${CC}"
  export CMAKE_AR="${AR}"
  export CMAKE_RANLIB="${RANLIB}"
  export CMAKE_LINKER="${_ecmv[ld]:-}"
  export CMAKE_NM="${_ecmv[nm]:-}"
  export CMAKE_OBJCOPY="${_ecmv[objcopy]}"
  export CMAKE_STRIP="${_ecmv[strip]}"
  export CMAKE_LIBRARY_ARCHITECTURE="${_ecmv[triplet]}"
  export CMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
  export CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
  export CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
}

_export_cargo_vars() {
  local -n _ecv=$1
  export CARGO_BUILD_TARGET="${_ecv[rust_target]}"
  export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/opt/cargo-target/${_ecv[target_arch]}}"
  export "CARGO_TARGET_${_ecv[rust_env]}_LINKER=${CC}"
  export "CARGO_TARGET_${_ecv[rust_env]}_AR=${AR}"
  # The `cc` crate (build scripts of ring, openssl-sys, …) does NOT read
  # CARGO_TARGET_*_LINKER — it needs CC_<target>/CXX_<target>. Without it, it
  # guesses `<triple>-gcc`, which for riscv64gc-unknown-linux-gnu does not exist,
  # so it falls back to the host gcc and passes it the target -mabi=lp64d flag →
  # "unrecognized argument in option '-mabi=lp64d'". Point it at the cross-GCC.
  local _cross_rust_env_lc
  _cross_rust_env_lc="$(cross_target_rust_triple | tr '[:upper:]-' '[:lower:]_')"
  export "CC_${_cross_rust_env_lc}=${CC}"
  [ -n "${CXX:-}" ] && export "CXX_${_cross_rust_env_lc}=${CXX}"
  [ -n "${AR:-}" ] && export "AR_${_cross_rust_env_lc}=${AR}"
}

# Export the full cross-compilation environment by dispatching to the per-group
# helpers above. Consumes the associative array with all keys produced by
# _cross_env_resolve_identifiers and _cross_env_resolve_tools.
_cross_env_export_all() {
  local -n _eea=$1
  _export_arch_vars     _eea
  _export_path
  _export_toolchain_vars _eea
  _export_pkg_config   _eea
  _export_library_path _eea
  _export_cmake_vars   _eea
  _export_cargo_vars   _eea
}

setup_linux_cross_env() {
  if ! cross_build_enabled; then
    return 0
  fi

  local -A _env=()

  _cross_env_resolve_identifiers _env
  _cross_env_setup_python_staging "${_env[target_arch]}"
  _cross_env_resolve_tools "${_env[triplet]}" _env || return 1
  _cross_env_export_all _env
}

# cross_compile_cmake_lib_from_source NAME URL[|MIRROR...] INSTALL_PREFIX SENTINEL [EXTRA_CMAKE_ARG...]
#
# URL may list '|'-separated fallback mirrors, tried in order until one lands
# (guards against a single-host outage silently disabling the lib). Each mirror is
# either a plain https tarball or a `git+<repo>#<ref>` spec (shallow git clone —
# reliable where the buildkit RUN can git-clone github.com but curl fails).
#
# Fetch a source tarball and cross-cmake build+install a small library into the
# target sysroot. For libraries whose Ubuntu Ports dev package is missing/broken,
# or whose OpenCV-vendored copy can't cross-build (freetype, libpng). No-op if
# SENTINEL already exists (e.g. an apt package already provided the lib).
#
# Behaviour-preserving extraction of the freetype/libpng blocks that were copy
# -pasted in 03-media/build/opencv/install-deps.sh: same cross toolchain
# (${triplet}-gcc/g++), same find-root scaffold. Per-library flags (FT_DISABLE_*,
# PNG_STATIC/PNG_HARDWARE_OPTIMIZATIONS, ZLIB_*, and any MODE_LIBRARY/INCLUDE
# override) are passed as trailing EXTRA_CMAKE_ARGs. Fetch goes through
# download_and_extract for curl --retry + temp-file hygiene (a hand-rolled
# `curl | tar` had neither). Never hard-fails: a download/build failure logs a
# WARN and returns 0 so the caller can degrade (e.g. OpenCV falls back to
# WITH_<lib>=OFF) instead of aborting the whole media stage.
cross_compile_cmake_lib_from_source() {
  local name="$1" url="$2" prefix="$3" sentinel="$4"
  shift 4

  local triplet arch src
  triplet="$(cross_target_triplet 2>/dev/null || true)"
  arch="$(cross_target_arch 2>/dev/null || true)"
  if [ -z "${triplet}" ]; then
    echo "[WARN] ${name}: no cross triplet resolved; skipping source build"
    return 0
  fi
  if [ -f "${sentinel}" ]; then
    return 0
  fi

  echo "[INFO] Cross-compiling ${name} from source for ${arch:-target} (${url})..."
  src="$(mktemp -d "${TMPDIR:-/tmp}/${name}-src-XXXXXX")" || return 0
  # URL may carry '|'-separated fallback mirrors so a single-source outage does
  # not skip the whole lib. Try each in order until one lands. Two mirror kinds:
  #   * a plain https tarball  -> download_and_extract (curl + strip 1)
  #   * a `git+<repo>#<ref>`   -> shallow git clone
  # The git kind exists because the buildkit RUN network can reach github.com via
  # git (OpenCV clones fine) + the apt mirrors, but curl to codeload.github.com /
  # downloads.sourceforge.net fails there — which is exactly what silently
  # disabled riscv64 OpenCV PNG across iree-0714a..0714e (2026-07-15). git clone
  # is the reliable primitive in that environment.
  # NOTE: split into a local array — do NOT `set --`, which would clobber the
  # extra cmake args still held in "$@" (used below) after the shift 4.
  local _dl_ok="" _u _repo _ref
  local -a _mirrors=()
  local _IFS_save="$IFS"; IFS='|' read -r -a _mirrors <<< "${url}"; IFS="${_IFS_save}"
  for _u in "${_mirrors[@]}"; do
    [ -n "${_u}" ] || continue
    case "${_u}" in
      git+*)
        _repo="${_u#git+}"; _ref="${_repo##*#}"; _repo="${_repo%#*}"
        rm -rf "${src}"
        if git clone --branch "${_ref}" --depth 1 "${_repo}" "${src}" >/dev/null 2>&1; then
          _dl_ok=1; break
        fi
        echo "[WARN] ${name}: git mirror failed (${_repo}@${_ref}); trying next"
        mkdir -p "${src}"
        ;;
      *)
        if download_and_extract "${_u}" "${src}" 1; then _dl_ok=1; break; fi
        echo "[WARN] ${name}: mirror failed (${_u}); trying next"
        ;;
    esac
  done
  if [ -z "${_dl_ok}" ]; then
    echo "[WARN] ${name}: source download failed (all mirrors); skipping"
    rm -rf "${src}"
    return 0
  fi
  if [ ! -f "${src}/CMakeLists.txt" ]; then
    echo "[WARN] ${name}: no CMakeLists.txt in source tree; skipping"
    rm -rf "${src}"
    return 0
  fi

  local -a cmake_args=(
    -DCMAKE_SYSTEM_NAME=Linux
    -DCMAKE_SYSTEM_PROCESSOR="${arch}"
    -DCMAKE_C_COMPILER="${triplet}-gcc"
    -DCMAKE_CXX_COMPILER="${triplet}-g++"
    -DCMAKE_FIND_ROOT_PATH="/usr/${triplet};/usr/lib/${triplet}"
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_INSTALL_PREFIX="${prefix}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    "$@"
  )
  if cmake -S "${src}" -B "${src}/build" "${cmake_args[@]}" \
     && cmake --build "${src}/build" --target install -j"$(nproc)"; then
    echo "[INFO] ${name}: installed to ${prefix}"
  else
    echo "[WARN] ${name}: source build/install failed; continuing without it"
  fi
  rm -rf "${src}"
}

