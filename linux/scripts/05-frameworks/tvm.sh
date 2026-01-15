#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source modules (search local repo first, then Docker image layout)
source_module() {
  local name="$1"
  local candidates=(
    "$SCRIPT_DIR/$name"
    "$SCRIPT_DIR/../01-core/$name"
    "$SCRIPT_DIR/../02-toolchain/$name"
    "/opt/scripts/core/$name"
    "/opt/scripts/toolchain/$name"
  )

  local c
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      # shellcheck disable=SC1090
      source "$c"
      return 0
    fi
  done

  echo "Error: required module '$name' not found (searched: ${candidates[*]})" >&2
  exit 1
}

source_module common.sh
source_module repos.sh
source_module core.sh
source_module llvm.sh
source_module gcc.sh

usage() {
  cat <<'EOF'
Build Apache TVM from source on Ubuntu 24.04.

Usage:
  tvm.sh [options]

Options:
  --workdir DIR        Directory to clone into (default: /opt/src if writable, else $HOME/src)
  --prefix DIR         Install prefix for 'cmake --install' (default: <workdir>/tvm-install)
  --ref REF            Git ref (branch/tag/commit) to checkout (default: main)
  --jobs N             Parallel build jobs (default: auto; respects cgroup CPU quota)
  --build-type TYPE    CMake build type (default: Release)
  --llvm-config PATH   Path to llvm-config binary (auto-detect if unset)
  --use-vulkan         Enable Vulkan runtime/codegen in TVM (default)
  --clean              Remove build dir before building
  --no-apt             Skip apt dependency installation
  --no-python          Skip Python venv + pip editable install
  -h, --help           Show this help

Environment overrides:
  TVM_WORKDIR, TVM_PREFIX, TVM_REF, TVM_JOBS, TVM_BUILD_TYPE, TVM_LLVM_CONFIG

Examples:
  ./tvm.sh
  ./tvm.sh --ref v0.16.0
  ./tvm.sh --llvm-config /usr/bin/llvm-config-21
  ./tvm.sh --clean --jobs 8
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

detect_llvm_config() {
  if [ -n "${TVM_LLVM_CONFIG:-}" ]; then
    echo "$TVM_LLVM_CONFIG"
    return 0
  fi

  local candidates=(
    "llvm-config"
    "llvm-config-18"
    "llvm-config-19"
    "llvm-config-20"
    "llvm-config-21"
  )

  local c
  for c in "${candidates[@]}"; do
    if command -v "$c" >/dev/null 2>&1; then
      command -v "$c"
      return 0
    fi
  done

  echo ""
}

install_deps() {
  require_sudo
  detect_system

  # Ensure the requested toolchains are installed/selected (defaults: clang 21, gcc 14)
  install_core_tools
  install_llvm_clang
  install_gcc

  # TVM build/runtime dependencies
  apt_install \
    pkg-config cmake ninja-build \
    python3 python3-venv python3-dev python3-pip \
    libopenblas-dev
}

detect_clang_tools() {
  local clang_bin="clang-${CLANG_WANTED}"
  local clangxx_bin="clang++-${CLANG_WANTED}"

  if ! command -v "$clang_bin" >/dev/null 2>&1; then
    clang_bin="clang"
  fi
  if ! command -v "$clangxx_bin" >/dev/null 2>&1; then
    clangxx_bin="clang++"
  fi

  echo "${clang_bin} ${clangxx_bin}"
}

detect_spirv_tools_library() {
  # TVM's Vulkan build requires the SPIRV-Tools *library*.
  local candidates=()

  # Prefer shared libs when present.
  shopt -s nullglob
  # Prefer the Vulkan SDK copy under /opt/vulkan. Prefer static to avoid runtime deps/RPATH.
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools.a)
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools-shared.so)
  candidates+=(/opt/vulkan/*/*/lib/libSPIRV-Tools.so)

  # If setup-env.sh sets VULKAN_SDK, also consider that location (it should still be under /opt/vulkan).
  if [ -n "${VULKAN_SDK:-}" ]; then
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools.a")
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools-shared.so")
    candidates+=("${VULKAN_SDK}/lib/libSPIRV-Tools.so")
  fi
  shopt -u nullglob

  local c
  for c in "${candidates[@]}"; do
    if [ -r "$c" ]; then
      echo "$c"
      return 0
    fi
  done

  echo ""
  return 1
}

is_under_opt_vulkan() {
  case "${1:-}" in
    /opt/vulkan/*) return 0 ;;
    *) return 1 ;;
  esac
}

filter_colon_list_excluding_prefix() {
  # Filters a colon-separated list, removing entries that start with the given prefix.
  # Usage: filter_colon_list_excluding_prefix "$LIST" "/opt/vulkan/"
  local list="${1:-}"
  local prefix="${2:-}"
  local out=""

  [ -n "$list" ] || { echo ""; return 0; }

  local IFS=':'
  local -a parts
  read -r -a parts <<<"$list"
  local p
  for p in "${parts[@]}"; do
    [ -n "$p" ] || continue
    case "$p" in
      "$prefix"*)
        continue
        ;;
    esac
    if [ -z "$out" ]; then
      out="$p"
    else
      out+="${IFS}${p}"
    fi
  done

  echo "$out"
}

sanitize_vulkan_sdk_env_for_build() {
  # The LunarG Vulkan SDK's setup-env.sh typically prepends /opt/vulkan/.../lib to
  # LD_LIBRARY_PATH and often touches CMAKE_PREFIX_PATH. That can lead to CMake RPATH
  # warnings/conflicts with system Vulkan loader libs.
  # Default: keep headers/tools but avoid using SDK lib directories for linking.
  if [ "${TVM_VULKAN_KEEP_SDK_LIBS:-0}" = "1" ]; then
    return 0
  fi

  if [ -n "${LD_LIBRARY_PATH:-}" ]; then
    LD_LIBRARY_PATH="$(filter_colon_list_excluding_prefix "$LD_LIBRARY_PATH" "/opt/vulkan/")"
    export LD_LIBRARY_PATH
  fi

  if [ -n "${CMAKE_PREFIX_PATH:-}" ]; then
    CMAKE_PREFIX_PATH="$(filter_colon_list_excluding_prefix "$CMAKE_PREFIX_PATH" "/opt/vulkan/")"
    export CMAKE_PREFIX_PATH
  fi
}

try_source_vulkan_env() {
  # If a LunarG Vulkan SDK has already been installed under /opt/vulkan,
  # source its setup-env.sh so CMake can find headers/tools.
  local prefix="${VULKAN_PREFIX:-/opt/vulkan}"

  if [ -n "${VULKAN_VERSION:-}" ] && [ -r "${prefix}/${VULKAN_VERSION}/setup-env.sh" ]; then
    # shellcheck disable=SC1090
    source "${prefix}/${VULKAN_VERSION}/setup-env.sh"
    sanitize_vulkan_sdk_env_for_build
    return 0
  fi

  local d
  for d in "${prefix}"/*; do
    [ -r "${d}/setup-env.sh" ] || continue
    # shellcheck disable=SC1090
    source "${d}/setup-env.sh"
    sanitize_vulkan_sdk_env_for_build
    return 0
  done

  return 1
}

have_vulkan_already() {
  # Return success when Vulkan headers + basic tools appear to be available.
  # This can be from apt packages or from a sourced Vulkan SDK.
  if [ -d /usr/include/vulkan ]; then
    return 0
  fi

  if [ -n "${VULKAN_SDK:-}" ] && [ -d "${VULKAN_SDK}/include/vulkan" ]; then
    return 0
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

main() {
  local workdir="${TVM_WORKDIR:-$(pick_default_workdir)}"
  local ref="${TVM_REF:-main}"
  local build_type="${TVM_BUILD_TYPE:-Release}"
  local jobs_arg="${TVM_JOBS:-}"
  local llvm_config="${TVM_LLVM_CONFIG:-}"
  local prefix="${TVM_PREFIX:-}"
  local use_vulkan="${TVM_USE_VULKAN:-1}"
  local do_clean=0
  local do_apt=1
  local do_python=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir)     workdir="$2"; shift 2 ;;
      --prefix)      prefix="$2"; shift 2 ;;
      --ref)         ref="$2"; shift 2 ;;
      --jobs)        jobs_arg="$2"; shift 2 ;;
      --build-type)  build_type="$2"; shift 2 ;;
      --llvm-config) llvm_config="$2"; shift 2 ;;
      --use-vulkan)  use_vulkan=1; shift ;;
      --clean)       do_clean=1; shift ;;
      --no-apt)      do_apt=0; shift ;;
      --no-python)   do_python=0; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  local jobs
  jobs="$(compute_jobs "${jobs_arg}")"

  mkdir -p "$workdir"
  local tvm_dir="$workdir/tvm"
  local build_dir="$tvm_dir/build"

  if [ -z "$prefix" ]; then
    prefix="$workdir/tvm-install"
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

  if [ ! -d "$tvm_dir/.git" ]; then
    log "Cloning TVM into $tvm_dir"
    git clone --recursive https://github.com/apache/tvm.git "$tvm_dir"
  fi

  log "Fetching + checking out ref: $ref"
  git -C "$tvm_dir" fetch --all --tags --prune
  git -C "$tvm_dir" checkout "$ref"
  git -C "$tvm_dir" submodule update --init --recursive

  if [ -z "$llvm_config" ]; then
    llvm_config="$(detect_llvm_config)"
  fi

  if [ -z "$llvm_config" ]; then
    log "llvm-config not found; continuing without LLVM (some TVM features will be disabled)"
  else
    log "Using LLVM: $llvm_config"
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

  log "Configuring CMake (type=$build_type)"
  local cmake_args=(
    -G Ninja
    -DCMAKE_BUILD_TYPE="$build_type"
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DUSE_OPENCL=OFF
    -DUSE_CUDA=OFF
    -DCMAKE_C_COMPILER="$desired_cc"
    -DCMAKE_CXX_COMPILER="$desired_cxx"
  )

  if [ "$use_vulkan" -eq 1 ]; then
    cmake_args+=( -DUSE_VULKAN=ON )
    # Help CMake/TVM find the SPIRV-Tools library reliably.
    local spirv_tools_lib=""
    spirv_tools_lib="$(detect_spirv_tools_library || true)"

    if [ -z "$spirv_tools_lib" ]; then
      die "Vulkan enabled but SPIRV-Tools library not found under /opt/vulkan. Install the Vulkan SDK so it provides libSPIRV-Tools."
    fi
    if ! is_under_opt_vulkan "$spirv_tools_lib"; then
      die "Vulkan enabled but SPIRV-Tools library resolved outside /opt/vulkan ($spirv_tools_lib). Only /opt/vulkan is allowed."
    fi

    cmake_args+=( -DVulkan_SPIRV_TOOLS_LIBRARY="$spirv_tools_lib" )
  else
    cmake_args+=( -DUSE_VULKAN=OFF )
  fi

  if [ -n "$llvm_config" ]; then
    cmake_args+=( -DUSE_LLVM="$llvm_config" )
  fi

  cmake -S "$tvm_dir" -B "$build_dir" "${cmake_args[@]}"

  log "Building TVM (jobs=$jobs)"
  cmake --build "$build_dir" --parallel "$jobs"

  log "Installing TVM to $prefix"
  cmake --install "$build_dir"

  if [ "$do_python" -eq 1 ]; then
    log "Setting up Python venv + editable TVM install"
    python3 -m venv "$tvm_dir/.venv"
    # shellcheck disable=SC1091
    source "$tvm_dir/.venv/bin/activate"

    python -m pip install -U pip setuptools wheel
    python -m pip install -U numpy cloudpickle decorator psutil scipy attrs

    # TVM depends on tvm-ffi for Python bindings.
    # Upstream docs: `cd 3rdparty/tvm-ffi; pip install .`
    if [ -f "$tvm_dir/3rdparty/tvm-ffi/pyproject.toml" ] || [ -f "$tvm_dir/3rdparty/tvm-ffi/setup.py" ]; then
      python -m pip install "$tvm_dir/3rdparty/tvm-ffi"
    else
      die "tvm-ffi is missing or not a Python project at $tvm_dir/3rdparty/tvm-ffi"
    fi

    # Install TVM python bindings (editable) and point it at the built libs
    export TVM_LIBRARY_PATH="$build_dir"
    python -m pip install -e "$tvm_dir/python"

    python - <<'PY'
import tvm
print("tvm imported OK; version=", tvm.__version__)
PY
  else
    log "Skipping Python setup (--no-python)"
  fi

  log "Done. Build dir: $build_dir"
  log "Install prefix: $prefix"
}

main "$@"
