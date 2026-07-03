#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
if [ -f "${SCRIPT_DIR}/../01-core/modules.sh" ]; then
  source "${SCRIPT_DIR}/../01-core/modules.sh"
elif [ -f "/opt/scripts/core/modules.sh" ]; then
  source "/opt/scripts/core/modules.sh"
else
  echo "Error: modules.sh not found (expected ${SCRIPT_DIR}/../01-core/modules.sh or /opt/scripts/core/modules.sh)" >&2
  exit 1
fi
source_modules_framework "${SCRIPT_DIR}"

source_module common.sh
source_module repos.sh
source_module core.sh
source_module llvm.sh
source_module gcc.sh
source_module vulkan.sh

for helper in \
  "/opt/scripts/core/cross-env.sh" \
  "${SCRIPT_DIR}/../01-core/cross-env.sh"; do
  if [ -f "${helper}" ]; then
    # shellcheck disable=SC1090
    source "${helper}"
    break
  fi
done

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/tvm-detect.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/tvm-config.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/tvm-python.sh"

usage() {
  cat <<'EOF'
Build Apache TVM from source on Ubuntu 24.04.

Usage:
  tvm.sh [options]

Options:
  --workdir DIR        Directory to clone into (default: /opt/src if writable, else $HOME/src)
  --prefix DIR         Install prefix for 'cmake --install' (default: <workdir>/tvm-install)
  --ref REF            Git ref (branch/tag/commit) to checkout (default: main)
  --build-type TYPE    CMake build type (default: Release)
  --llvm-config PATH   Path to llvm-config binary (auto-detect if unset)
  --llvm-dir DIR       Path to LLVM CMake package dir (uses LLVMConfig.cmake)
  --use-vulkan         Enable Vulkan runtime/codegen in TVM (default)
  --clean              Remove build dir before building
  --no-apt             Skip apt dependency installation
  --no-python          Skip Python venv + pip editable install
  -h, --help           Show this help

Environment overrides:
  TVM_WORKDIR, TVM_PREFIX, TVM_REF, TVM_BUILD_TYPE, TVM_LLVM_CONFIG, TVM_LLVM_DIR
  TVM_JOBS (optional override for parallel build jobs)
  TVM_MB_PER_JOB (optional; default: 2000)

Examples:
  ./tvm.sh
  ./tvm.sh --ref v0.23.0
  ./tvm.sh --llvm-config /usr/bin/llvm-config-21
  ./tvm.sh --clean
EOF
}

pick_default_workdir() {
  # Prefer /opt/src (container-friendly) if writable; otherwise use $HOME/src
  if [ -w /opt ] || [ -w /opt/src ] || { mkdir -p /opt/src 2>/dev/null && [ -w /opt/src ]; }; then
    echo "/opt/src"
  else
    echo "${HOME}/src"
  fi
}

install_deps() {
  require_sudo
  detect_system

  # Dockerfile.toolchain already provides the compiler toolchain and source-built
  # Python interpreter for this image. Keep TVM's apt step limited to framework
  # dependencies so this script consumes that toolchain instead of reinstalling it.
  apt_install \
    pkg-config ninja-build \
    libopenblas-dev
}

require_toolchain_compilers() {
  local gcc_bin="gcc-${GCC_WANTED}"
  local gxx_bin="g++-${GCC_WANTED}"

  command -v "$gcc_bin" >/dev/null 2>&1 || gcc_bin="gcc"
  command -v "$gxx_bin" >/dev/null 2>&1 || gxx_bin="g++"

  command -v "$gcc_bin" >/dev/null 2>&1 || die "Expected GCC from linux/Dockerfile.toolchain, but '${gcc_bin}' is unavailable"
  command -v "$gxx_bin" >/dev/null 2>&1 || die "Expected G++ from linux/Dockerfile.toolchain, but '${gxx_bin}' is unavailable"

  if [ -n "${CC:-}" ]; then
    command -v "${CC}" >/dev/null 2>&1 || die "CC=${CC} is set but not available"
  fi
  if [ -n "${CXX:-}" ]; then
    command -v "${CXX}" >/dev/null 2>&1 || die "CXX=${CXX} is set but not available"
  fi
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/tvm-llvm-compat.sh"


# TVM v0.25.0 already includes LLVM 22 compatibility fixes.
# patch_tvm_for_llvm_22 was removed after the v0.24.0 -> v0.25.0 bump.

main() {
  local workdir="${TVM_WORKDIR:-$(pick_default_workdir)}"
  local ref="${TVM_REF:-main}"
  local build_type="${TVM_BUILD_TYPE:-Release}"
  local llvm_config="${TVM_LLVM_CONFIG:-}"
  local llvm_dir="${TVM_LLVM_DIR:-}"
  local llvm_ignore_paths=""
  local prefix="${TVM_PREFIX:-}"
  local use_vulkan="${TVM_USE_VULKAN:-1}"
  local use_cuda="${TVM_USE_CUDA:-0}"
  local use_opencl="${TVM_USE_OPENCL:-0}"
  local requested_jobs="${TVM_JOBS:-}"
  local mb_per_job="${TVM_MB_PER_JOB:-2000}"
  local llvm_cmake_value="OFF"
  local do_clean=0
  local do_apt=1
  local do_python=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir)     workdir="$2"; shift 2 ;;
      --prefix)      prefix="$2"; shift 2 ;;
      --ref)         ref="$2"; shift 2 ;;
      --build-type)  build_type="$2"; shift 2 ;;
      --llvm-config) llvm_config="$2"; shift 2 ;;
      --llvm-dir)    llvm_dir="$2"; shift 2 ;;
      --use-vulkan)  use_vulkan=1; shift ;;
      --use-cuda)   use_cuda=1; shift ;;
      --use-opencl) use_opencl=1; shift ;;
      --clean)       do_clean=1; shift ;;
      --no-apt)      do_apt=0; shift ;;
      --no-python)   do_python=0; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  local jobs
  jobs="$(compute_jobs_with_mem_cap "${requested_jobs}" "${mb_per_job}")"

  mkdir -p "$workdir"
  local tvm_dir="$workdir/tvm"
  local build_dir="$tvm_dir/build"

  if [ -z "$prefix" ]; then
    prefix="$workdir/tvm-install"
  fi

  if cross_build_is_active; then
    setup_linux_cross_env
  fi

  if [ "$do_apt" -eq 1 ]; then
    log "Installing build dependencies via apt"
    install_deps
    if [ "$use_vulkan" -eq 1 ]; then
      # If Vulkan SDK is already installed, try to source it and avoid extra apt installs.
      if try_source_vulkan_env; then
        log "Detected Vulkan SDK under ${VULKAN_PREFIX:-/opt/vulkan}; sourced setup-env.sh"
      fi
    fi
  else
    log "Skipping apt dependency installation (--no-apt)"
  fi

  require_toolchain_compilers

  local _tvm_cloned=0
  if [ ! -d "$tvm_dir/.git" ]; then
    log "Cloning TVM into $tvm_dir"
    git clone --recursive https://github.com/apache/tvm.git "$tvm_dir"
    _tvm_cloned=1
  fi

  local _curr_ref; _curr_ref="$(git -C "$tvm_dir" rev-parse HEAD 2>/dev/null || true)"
  log "Fetching + checking out ref: $ref"
  git -C "$tvm_dir" fetch --depth 1 origin "${ref}" 2>/dev/null || git -C "$tvm_dir" fetch --depth 1 --tags 2>/dev/null || true
  git -C "$tvm_dir" checkout "${ref}"
  if [ "$_tvm_cloned" -eq 0 ] || [ "$_curr_ref" != "$(git -C "$tvm_dir" rev-parse HEAD 2>/dev/null || true)" ]; then
    git -C "$tvm_dir" submodule update --init --recursive
  fi

  if [ -z "$llvm_config" ]; then
    llvm_config="$(detect_llvm_config)"
  fi

  if [ -n "$llvm_dir" ]; then
    llvm_dir="$(normalize_llvm_cmake_dir "$llvm_dir")"
  fi

  if cross_build_is_active; then
    if [ -z "$llvm_dir" ]; then
      llvm_dir="$(detect_cross_llvm_cmake_dir)"
    fi
    if [ -n "$llvm_dir" ]; then
      llvm_dir="$(normalize_llvm_cmake_dir "$llvm_dir")"
      validate_detected_llvm_cmake_package "$llvm_dir"
    fi
    if [ -n "$llvm_dir" ]; then
      log "Using target LLVM CMake package: $llvm_dir"
      llvm_cmake_value="ON"
    else
      llvm_config="$(sanitize_llvm_config_for_target "$llvm_config")"
    fi
  else
    llvm_config="$(sanitize_llvm_config_for_target "$llvm_config")"
  fi

  if [ -n "$llvm_dir" ] && cross_build_is_active; then
    llvm_ignore_paths="$(detect_vulkan_llvm_cmake_ignore_paths)"
    if [ -n "${llvm_ignore_paths}" ]; then
      log "Ignoring Vulkan LLVM CMake packages: ${llvm_ignore_paths}"
    fi
  fi

  if [ -n "$llvm_dir" ]; then
    :
  elif [ -z "$llvm_config" ]; then
    log "llvm-config not found; continuing without LLVM (some TVM features will be disabled)"
  else
    log "Using LLVM: $llvm_config"
    llvm_cmake_value="$llvm_config"
  fi

  if [ "$do_clean" -eq 1 ]; then
    log "Cleaning build directory: $build_dir"
    rm -rf "$build_dir"
  fi

  mkdir -p "$build_dir"

  # Decide toolchain.
  # Default to GCC/G++ to avoid known LLVM-packaging header conflicts with clang++ on Ubuntu.
  local gcc_bin="gcc-${GCC_WANTED}"
  local gxx_bin="g++-${GCC_WANTED}"
  command -v "$gcc_bin" >/dev/null 2>&1 || gcc_bin="gcc"
  command -v "$gxx_bin" >/dev/null 2>&1 || gxx_bin="g++"

  local desired_cc
  local desired_cxx
  desired_cc="$(command -v "${CC:-$gcc_bin}" 2>/dev/null || echo "${CC:-$gcc_bin}")"
  desired_cxx="$(command -v "${CXX:-$gxx_bin}" 2>/dev/null || echo "${CXX:-$gxx_bin}")"

  # If LLVM injects an include dir containing a conflicting cxxabi.h, prefer GCC's header.
  # This does not change the chosen C++ standard library; it only fixes header precedence.
  local wrapped
  wrapped="$(maybe_wrap_compiler_to_prefer_gcc_cxxabi_header "$llvm_config" "$build_dir" "$desired_cc" "$desired_cxx")"
  desired_cc="${wrapped%% *}"
  desired_cxx="${wrapped#* }"

  log "Configuring CMake (type=$build_type)"
  local cmake_args=(
    -G Ninja
    -DCMAKE_INSTALL_PREFIX="$prefix"
  )
  local cross_link_flags=""
  local spirv_tools_lib=""

  if cross_build_is_active; then
    cross_link_flags="$(cross_linker_search_flags || true)"
  fi

  if [ "$use_vulkan" -eq 1 ]; then
    # Help CMake/TVM find the SPIRV-Tools library reliably.
    spirv_tools_lib="$(detect_spirv_tools_library || true)"

    # Check SPIRV-Tools arch matches target arch (loaded SDK libs may be x86_64 only).
    if [ -n "$spirv_tools_lib" ] && [ -f "$spirv_tools_lib" ] && command -v readelf >/dev/null 2>&1; then
      local _st_machine
      _st_machine="$(readelf -h "$spirv_tools_lib" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -1)"
      local _tvm_target_arch
      _tvm_target_arch="$(cross_target_arch 2>/dev/null || echo "amd64")"
      local _st_expected
      _st_expected="$(arch_elf_machine_grep_for "${_tvm_target_arch}" 2>/dev/null || true)"
      if [ -n "${_st_expected}" ] && ! echo "${_st_machine}" | grep -qF "${_st_expected}"; then
        log "SPIRV-Tools library ${spirv_tools_lib} has ELF machine '${_st_machine}' but target is ${_tvm_target_arch} ('${_st_expected}'). Building with USE_VULKAN=ON without SPIRV-Tools."
        spirv_tools_lib=""
      fi
    fi

    if [ -z "$spirv_tools_lib" ]; then
      log "Vulkan enabled without SPIRV-Tools library; TVM will use Vulkan without SPIRV assembly support."
    elif ! is_under_opt_vulkan "$spirv_tools_lib"; then
      die "Vulkan enabled but SPIRV-Tools library resolved outside /opt/vulkan ($spirv_tools_lib). Only /opt/vulkan is allowed."
    fi
  fi

  append_tvm_cmake_args \
    cmake_args \
    OFF \
    "$build_type" \
    "$desired_cc" \
    "$desired_cxx" \
    "$llvm_cmake_value" \
    "$llvm_dir" \
    "$llvm_ignore_paths" \
    "$use_vulkan" \
    "$use_cuda" \
    "$use_opencl" \
    "$spirv_tools_lib" \
    "$cross_link_flags"

  cmake -S "$tvm_dir" -B "$build_dir" "${cmake_args[@]}"

  log "Building TVM (jobs=$jobs, mb_per_job=$mb_per_job)"
  cmake --build "$build_dir" --parallel "$jobs"

  log "Installing TVM to $prefix"
  cmake --install "$build_dir"

  if [ "$do_python" -eq 1 ]; then
    tvm_build_wheel
  else
    log "Skipping Python setup (--no-python)"
  fi

  log "Done. Build dir: $build_dir"
  log "Install prefix: $prefix"
}

main "$@"
