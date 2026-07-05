#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain source-only helper.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "This script is meant to be sourced, not executed" >&2
  exit 1
fi
set -euo pipefail

llvm_build_script() {
  local script_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${script_dir}/build-clang.sh" ]; then
    printf '%s' "${script_dir}/build-clang.sh"
    return 0
  fi

  if [ -f "/opt/scripts/toolchain/build-clang.sh" ]; then
    printf '%s' "/opt/scripts/toolchain/build-clang.sh"
    return 0
  fi

  return 1
}

build_llvm_clang_from_source() {
  local builder
  local -a args=(--version "${CLANG_WANTED}" --ccache)

  builder="$(llvm_build_script)" || die "LLVM source build script not found"
  [ -n "${LLVM_RELEASE:-}" ] && args+=(--release "${LLVM_RELEASE}")

  log "apt.llvm.org does not publish LLVM ${CLANG_WANTED} for Ubuntu ${DISTRO}; building from source"
  chmod +x "${builder}" || true
  bash "${builder}" "${args[@]}"
}

# Resolve a host LLVM tool by base name, preferring the version-suffixed
# variant (e.g. clang-${CLANG_WANTED}) then the bare name. Prints the resolved
# path, returns 1 if none found.
llvm_selected_host_tool() {
  local base="$1" candidate=""
  for candidate in "${base}-${CLANG_WANTED}" "${base}"; do
    command -v "${candidate}" >/dev/null 2>&1 || continue
    command -v "${candidate}"
    return 0
  done
  return 1
}

llvm_selected_host_clang() { llvm_selected_host_tool clang; }
llvm_selected_host_clangxx() { llvm_selected_host_tool clang++; }

register_versioned_llvm_binaries() {
  local full base tool

  # Register every versioned binary we find under /usr/bin that ends with -${CLANG_WANTED}
  # and set it as the chosen alternative.
  for full in /usr/bin/*-"${CLANG_WANTED}"; do
    [ -e "$full" ] || continue

    base="$(basename "$full")"
    tool="${base%-${CLANG_WANTED}}"

    alt_install_and_set "${tool}" "/usr/bin/${tool}" "$full" 100
  done
}

install_cross_clang_wrappers() {
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local gcc_prefix target target_label triplet sysroot wrapper host_clang host_clangxx

  cross_mode_requested || return 0

  host_clang="$(llvm_selected_host_clang)" || die "Host clang is unavailable"
  host_clangxx="$(llvm_selected_host_clangxx)" || die "Host clang++ is unavailable"
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || die "Unsupported LLVM cross target list: ${targets_raw}"

  gcc_prefix="$(gcc_toolchain_prefix 2>/dev/null || true)"
  [ -d "${gcc_prefix}" ] || gcc_prefix="/usr"

  for target in ${targets_raw//,/ }; do
    target_label="$(arch_normalize "$target")"
    case "${target_label}" in
      amd64|arm64|riscv64) ;;
      *)
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
      ;;
    esac
    triplet="$(arch_deb_multiarch_triplet_for "$target_label")" || continue
    if [ "${target_label}" = "amd64" ]; then
      sysroot="/"
    else
      sysroot="/usr/${triplet}"
      [ -d "${sysroot}" ] || die "Expected cross sysroot not found for ${target_label}: ${sysroot}"
    fi

    local _pair _name _bin
    for _pair in "clang:${host_clang}" "clang++:${host_clangxx}"; do
      _name="${_pair%%:*}"; _bin="${_pair#*:}"
      wrapper="/usr/local/bin/${_name}-${target_label}"
      cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec "${_bin}" --target=${triplet} --sysroot=${sysroot} --gcc-toolchain=${gcc_prefix} "\$@"
EOF
      chmod +x "${wrapper}"
      log "Installed LLVM wrapper: $(basename "${wrapper}")"
    done
  done
}

# Mapping lives in 01-core/arch-mapping.sh (loaded via common.sh).
llvm_cross_backend() {
  arch_to_llvm_target "$1" 2>/dev/null
}

llvm_cross_root() {
  printf '%s' "${LLVM_CROSS_ROOT:-/opt/llvm-cross}"
}

llvm_cross_install_prefix() {
  local triplet

  triplet="$(arch_deb_multiarch_triplet_for "$1")" || return 1
  printf '%s' "$(llvm_cross_root)/${triplet}"
}

llvm_cross_bin_dir() {
  local prefix

  prefix="$(llvm_cross_install_prefix "$1")" || return 1
  printf '%s' "${prefix}/bin"
}

llvm_cross_lib_dir() {
  local prefix="$1"
  local dir

  for dir in \
    "${prefix}/lib" \
    "${prefix}/lib64"; do
    [ -d "${dir}" ] || continue
    printf '%s' "${dir}"
    return 0
  done

  return 1
}

llvm_cross_cmake_dir() {
  local prefix
  local dir

  prefix="$(llvm_cross_install_prefix "$1")" || return 1
  for dir in \
    "${prefix}/lib/cmake/llvm" \
    "${prefix}/lib64/cmake/llvm"; do
    [ -f "${dir}/LLVMConfig.cmake" ] || continue
    printf '%s' "${dir}"
    return 0
  done

  return 1
}

llvm_cross_shared_umbrella_lib_path() {
  local prefix="$1"
  local candidate

  for candidate in \
    "${prefix}/lib/libLLVM.so" \
    "${prefix}/lib64/libLLVM.so"; do
    [ -e "${candidate}" ] || continue
    printf '%s' "${candidate}"
    return 0
  done

  return 1
}

llvm_cross_versioned_shared_umbrella_lib_path() {
  local prefix="$1"
  local candidate
  local nullglob_was_set=0
  local -a matches=()

  case ":${BASHOPTS}:" in
    *:nullglob:*) nullglob_was_set=1 ;;
  esac
  shopt -s nullglob
  matches=("${prefix}/lib"/libLLVM.so.* "${prefix}/lib64"/libLLVM.so.*)
  if [ "${nullglob_was_set}" -eq 0 ]; then
    shopt -u nullglob
  fi

  for candidate in "${matches[@]}"; do
    [ -e "${candidate}" ] || continue
    printf '%s' "${candidate}"
    return 0
  done

  return 1
}

llvm_cross_compat_shared_umbrella_lib_path() {
  local prefix="$1"
  local major="$(llvm_wanted_major)"
  local candidate

  major="$(version_major "${major}")"
  for candidate in \
    "${prefix}/lib/libLLVM-${major}.so" \
    "${prefix}/lib64/libLLVM-${major}.so"; do
    [ -e "${candidate}" ] || continue
    printf '%s' "${candidate}"
    return 0
  done

  return 1
}

llvm_cross_llvm_config_path() {
  local prefix="$1"
  local major="$(llvm_wanted_major)"
  local candidate

  major="$(version_major "${major}")"
  for candidate in \
    "${prefix}/bin/llvm-config" \
    "${prefix}/bin/llvm-config-${major}"; do
    [ -x "${candidate}" ] || continue
    printf '%s' "${candidate}"
    return 0
  done

  return 1
}

llvm_cross_install_looks_complete() {
  local target_label="$1"
  local prefix

  prefix="$(llvm_cross_install_prefix "${target_label}")" || return 1
  llvm_cross_cmake_dir "${target_label}" >/dev/null 2>&1 || return 1
  llvm_cross_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || return 1
  llvm_cross_versioned_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || return 1
  llvm_cross_compat_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || return 1
  llvm_cross_llvm_config_path "${prefix}" >/dev/null 2>&1 || return 1
  return 0
}

llvm_cross_first_executable() {
  _cross_first_executable "$@"
}

llvm_cross_qemu_binary() {
  case "$1" in
    arm64)
      llvm_cross_first_executable qemu-aarch64 qemu-aarch64-static
      ;;
    riscv64)
      llvm_cross_first_executable qemu-riscv64 qemu-riscv64-static
      ;;
    amd64)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

llvm_cross_qemu_sysroot() {
  local target_label="$1"
  local triplet candidate loader
  local -a loaders=()

  [ "${target_label}" = "amd64" ] && {
    printf '%s' "/"
    return 0
  }

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || return 1
  case "${target_label}" in
    arm64)
      loaders=(
        "lib/ld-linux-aarch64.so.1"
      )
      ;;
    riscv64)
      loaders=(
        "lib/ld-linux-riscv64-lp64d.so.1"
        "lib/ld-linux-riscv64-lp64.so.1"
        "lib/ld-linux-riscv64-ilp32d.so.1"
        "lib/ld-linux-riscv64-ilp32.so.1"
      )
      ;;
    *)
      return 1
      ;;
  esac

  for candidate in "/usr/${triplet}" "/"; do
    for loader in "${loaders[@]}"; do
      [ -e "${candidate}/${loader}" ] || continue
      printf '%s' "${candidate}"
      return 0
    done
  done

  return 1
}

llvm_cross_target_runtime_library_path() {
  local target_label="$1"
  local prefix triplet gcc_prefix gcc_major runtime_libdir path="" dir

  prefix="$(llvm_cross_install_prefix "${target_label}")" || return 1
  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || return 1
  gcc_prefix="$(gcc_toolchain_prefix 2>/dev/null || true)"
  [ -n "${gcc_prefix}" ] || gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  gcc_major="${GCC_WANTED:-16}"
  gcc_major="$(version_major "${gcc_major}")"
  runtime_libdir="${gcc_prefix}/lib/gcc/${triplet}/${gcc_major}"

  for dir in \
    "${prefix}/lib" \
    "${prefix}/lib64" \
    "${runtime_libdir}" \
    "${gcc_prefix}/${triplet}/lib" \
    "${gcc_prefix}/${triplet}/lib64" \
    "${gcc_prefix}/lib64" \
    "${gcc_prefix}/lib" \
    "/lib/${triplet}" \
    "/usr/lib/${triplet}" \
    "/usr/${triplet}/lib"; do
    [ -d "${dir}" ] || continue
    case ":${path}:" in
      *":${dir}:"*)
        ;;
      *)
        path="${path:+${path}:}${dir}"
        ;;
    esac
  done

  printf '%s' "${path}"
}

llvm_cross_run_binary() {
  local target_label="$1"
  shift

  [ "$#" -gt 0 ] || return 1
  if [ "${target_label}" = "amd64" ]; then
    "$@"
    return 0
  fi

  local qemu_bin qemu_sysroot target_ld_library_path
  local -a qemu_args=()

  qemu_bin="$(llvm_cross_qemu_binary "${target_label}")" || \
    die "No qemu user-mode runner available for target LLVM ${target_label}"
  qemu_sysroot="$(llvm_cross_qemu_sysroot "${target_label}")" || \
    die "Could not locate a qemu sysroot for target LLVM ${target_label}"
  target_ld_library_path="$(llvm_cross_target_runtime_library_path "${target_label}")"

  qemu_args=("${qemu_bin}" -L "${qemu_sysroot}")
  if [ -n "${target_ld_library_path}" ]; then
    qemu_args+=( -E "LD_LIBRARY_PATH=${target_ld_library_path}" )
  fi

  env -u LD_LIBRARY_PATH "${qemu_args[@]}" "$@"
}

llvm_cross_populate_tool_wrapper_dir() {
  local wrapper_dir="$1"
  local tool

  mkdir -p "${wrapper_dir}"
  for tool in as ld ar nm ranlib strip objcopy; do
    # AS, LD, AR, NM, RANLIB, STRIP, OBJCOPY — env var name is the tool upper-cased
    local _tv="${tool^^}"
    ln -sfn "${!_tv}" "${wrapper_dir}/${tool}"
  done
}

_LLVM_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LLVM_SH_DIR}/llvm-validate.sh"

llvm_host_native_tool_dir() {
  local major="$(llvm_wanted_major)"
  local candidate

  major="$(version_major "${major}")"

  for candidate in \
    "/usr/local/llvm-${major}/bin" \
    "/usr/lib/llvm-${major}/bin" \
    "/usr/local/bin"; do
    [ -x "${candidate}/llvm-tblgen" ] || continue
    printf '%s' "${candidate}"
    return 0
  done

  if command -v llvm-tblgen >/dev/null 2>&1; then
    dirname "$(command -v llvm-tblgen)"
    return 0
  fi

  return 1
}

source "${_LLVM_SH_DIR}/llvm-cross.sh"

install_llvm_clang_minimal() {
  log "Installing minimal LLVM/Clang ${CLANG_WANTED}"
  add_llvm_repo
  apt_update_once

  apt_install_available \
    "clang-${CLANG_WANTED}" \
    "lld-${CLANG_WANTED}" \
    "lldb-${CLANG_WANTED}" \
    "llvm-${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}-dev" \
    "llvm-${LLVM_WANTED}-runtime" \
    "libclang-${CLANG_WANTED}-dev" \
    "libclang-rt-${CLANG_WANTED}-dev" \
    "libfuzzer-${CLANG_WANTED}-dev" \
    "libc++-${CLANG_WANTED}-dev" \
    "libc++abi-${CLANG_WANTED}-dev" \
    "libclang1-${CLANG_WANTED}"
}

install_llvm_clang_full() {
  log "Installing full LLVM/Clang ${CLANG_WANTED} (LLVM ${LLVM_WANTED})"
  add_llvm_repo
  apt_update_once

  # Base LLVM + Clang toolchain
  apt_install_available \
    "libllvm${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}-dev" \
    "llvm-${LLVM_WANTED}-runtime" \
    "clang-${CLANG_WANTED}" \
    "clang-tools-${CLANG_WANTED}" \
    "clangd-${CLANG_WANTED}" \
    "clang-tidy-${CLANG_WANTED}" \
    "clang-format-${CLANG_WANTED}" \
    "python3-clang-${CLANG_WANTED}" \
    "libclang-common-${CLANG_WANTED}-dev" \
    "libclang-${CLANG_WANTED}-dev" \
    "libclang1-${CLANG_WANTED}" \
    "lld-${CLANG_WANTED}" \
    "lldb-${CLANG_WANTED}"

  # Commonly useful extras from apt.llvm.org (installed when present)
  apt_install_available \
    "libclang-rt-${CLANG_WANTED}-dev" \
    "libpolly-${CLANG_WANTED}-dev" \
    "libfuzzer-${CLANG_WANTED}-dev" \
    "libc++-${CLANG_WANTED}-dev" \
    "libc++abi-${CLANG_WANTED}-dev" \
    "libomp-${CLANG_WANTED}-dev" \
    "libclc-${CLANG_WANTED}-dev" \
    "libunwind-${CLANG_WANTED}-dev" \
    "libmlir-${CLANG_WANTED}-dev" \
    "mlir-${CLANG_WANTED}-tools" \
    "libbolt-${CLANG_WANTED}-dev" \
    "bolt-${CLANG_WANTED}" \
    "flang-${CLANG_WANTED}" \
    "libllvmlibc-${CLANG_WANTED}-dev"
}

install_llvm_clang() {
  # Default to a complete install; override with LLVM_INSTALL_PROFILE=minimal if desired.
  local profile="${LLVM_INSTALL_PROFILE:-full}"
  local installed_from_source=0
  local target_arch=""

  target_arch="$(arch_normalize "${TARGET_ARCH:-${TARGETARCH:-${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}}}")"

  if ! cross_mode_requested && [ "${target_arch}" = "riscv64" ]; then
    log "apt.llvm.org does not provide prebuilt LLVM/Clang packages for riscv64; building LLVM/Clang ${CLANG_WANTED} from source"
    build_llvm_clang_from_source
    installed_from_source=1
  elif declare -F llvm_repo_available >/dev/null 2>&1 && ! llvm_repo_available "${DISTRO}"; then
    build_llvm_clang_from_source
    installed_from_source=1
  else
    case "$profile" in
      full)    install_llvm_clang_full ;;
      minimal) install_llvm_clang_minimal ;;
      *) die "Unknown LLVM_INSTALL_PROFILE: ${profile} (expected: full|minimal)" ;;
    esac

    register_versioned_llvm_binaries
  fi

  # Show versions (non-fatal)
  tool_version clang --version
  tool_version clang++ --version
  tool_version clangd --version
  tool_version clang-format --version
  tool_version clang-tidy --version
  tool_version lld --version
  tool_version lldb --version
  tool_version llvm-config --version

  # Useful LLVM/MLIR/BOLT/Flang tools (present depending on installed packages)
  tool_version llvm-ar --version
  tool_version llvm-nm --version
  tool_version llvm-objdump --version
  tool_version llvm-profdata --version
  tool_version opt --version
  tool_version llc --version
  tool_version mlir-opt --version
  tool_version bolt --version
  tool_version flang --version
  tool_version flang-new --version

  [ "${installed_from_source}" = "1" ] && log "Installed LLVM/Clang ${CLANG_WANTED} from source"
  install_cross_clang_wrappers
  install_cross_llvm_runner_tools
  build_cross_llvm_targets
}

