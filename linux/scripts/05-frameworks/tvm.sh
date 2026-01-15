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

gcc_multiarch() {
  # e.g. x86_64-linux-gnu
  local gcc_bin
  gcc_bin="$(command -v "gcc-${GCC_WANTED}" 2>/dev/null || command -v gcc 2>/dev/null || echo "")"
  if [ -n "$gcc_bin" ]; then
    "$gcc_bin" -print-multiarch 2>/dev/null || true
  fi
}

gcc_cxx_include_paths() {
  # Colon-separated list suitable for CPLUS_INCLUDE_PATH.
  # TVM's LLVM integration adds /usr/lib/llvm-*/include as an -isystem path.
  # On Ubuntu, that directory can ship a libc++abi cxxabi.h which conflicts with
  # GCC/libstdc++ headers. For Clang, CPLUS_INCLUDE_PATH is searched early and
  # ensures <cxxabi.h> resolves to libstdc++.
  local v="${GCC_WANTED}"
  local ma
  ma="$(gcc_multiarch)"
  if [ -n "$ma" ] && [ -d "/usr/include/${ma}/c++/${v}" ]; then
    echo "/usr/include/c++/${v}:/usr/include/${ma}/c++/${v}:/usr/include/c++/${v}/backward"
  elif [ -d "/usr/include/c++/${v}" ]; then
    echo "/usr/include/c++/${v}:/usr/include/c++/${v}/backward"
  else
    echo ""
  fi
}

gcc_cxx_include_flags() {
  # Return -I flags for GCC/libstdc++ include dirs.
  # Using -I (not -isystem) ensures these headers win over LLVM's -isystem include dir.
  local v="${GCC_WANTED}"
  local ma
  ma="$(gcc_multiarch)"
  if [ -n "$ma" ] && [ -d "/usr/include/${ma}/c++/${v}" ]; then
    echo "-I/usr/include/c++/${v} -I/usr/include/${ma}/c++/${v} -I/usr/include/c++/${v}/backward"
  elif [ -d "/usr/include/c++/${v}" ]; then
    echo "-I/usr/include/c++/${v} -I/usr/include/c++/${v}/backward"
  else
    echo ""
  fi
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

disable_llvm_cxxabi_header_if_present() {
  # Some Ubuntu LLVM packages ship a libc++abi-flavoured cxxabi.h in LLVM's include dir.
  # TVM (via dmlc-core) includes <cxxabi.h>, and Clang may pick LLVM's copy first,
  # which can conflict with GCC/libstdc++ headers.
  #
  # This function temporarily moves that header aside for the duration of the build.
  local llvm_config_bin="${1:-}"
  [ -n "$llvm_config_bin" ] || return 0
  command -v "$llvm_config_bin" >/dev/null 2>&1 || return 0

  local incdir
  incdir="$("$llvm_config_bin" --includedir 2>/dev/null || true)"
  [ -n "$incdir" ] || return 0

  local header="${incdir}/cxxabi.h"
  local backup="${incdir}/cxxabi.h.disabled-by-kataglyphis"

  [ -f "$header" ] || return 0
  [ -f "$backup" ] && return 0

  if [ "$(id -u)" -ne 0 ]; then
    require_sudo
    sudo mv "$header" "$backup"
  else
    mv "$header" "$backup"
  fi

  export TVM_LLVM_CXXABI_BACKUP="$backup"
  log "Temporarily disabled LLVM cxxabi.h to avoid GCC/libstdc++ conflicts"

  trap 'if [ -n "${TVM_LLVM_CXXABI_BACKUP:-}" ] && [ -f "${TVM_LLVM_CXXABI_BACKUP}" ]; then
          orig="${TVM_LLVM_CXXABI_BACKUP%.disabled-by-kataglyphis}";
          if [ "$(id -u)" -ne 0 ]; then
            sudo mv "${TVM_LLVM_CXXABI_BACKUP}" "$orig";
          else
            mv "${TVM_LLVM_CXXABI_BACKUP}" "$orig";
          fi;
        fi' EXIT
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

  if [ -n "$llvm_config" ]; then
    disable_llvm_cxxabi_header_if_present "$llvm_config"
  fi

  if [ "$do_clean" -eq 1 ]; then
    log "Cleaning build directory: $build_dir"
    rm -rf "$build_dir"
  fi

  mkdir -p "$build_dir"

  # Decide toolchain and stdlib mode.
  read -r clang_bin clangxx_bin <<<"$(detect_clang_tools)"
  local desired_cc
  local desired_cxx
  desired_cc="$(command -v "${CC:-$clang_bin}" 2>/dev/null || echo "${CC:-$clang_bin}")"
  desired_cxx="$(command -v "${CXX:-$clangxx_bin}" 2>/dev/null || echo "${CXX:-$clangxx_bin}")"

  # LLVM can inject an alternative cxxabi.h via its include directory.
  # Ensure we consistently use GCC/libstdc++ headers when building with Clang.
  if [ -n "$llvm_config" ]; then
    case "$desired_cxx" in
      *clang++*)
        local gcc_include_paths=""
        gcc_include_paths="$(gcc_cxx_include_paths)"
        if [ -n "$gcc_include_paths" ]; then
          if [ -n "${CPLUS_INCLUDE_PATH:-}" ]; then
            export CPLUS_INCLUDE_PATH="${gcc_include_paths}:${CPLUS_INCLUDE_PATH}"
          else
            export CPLUS_INCLUDE_PATH="${gcc_include_paths}"
          fi
          log "Applied GCC libstdc++ header precedence via CPLUS_INCLUDE_PATH"
        else
          log "Warning: could not determine GCC C++ include dirs; build may hit cxxabi.h conflicts"
        fi
        ;;
    esac
  fi

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

  # Ensure GCC/libstdc++ headers take precedence over LLVM's libc++abi cxxabi.h.
  if [ -n "$llvm_config" ]; then
    case "$desired_cxx" in
      *clang++*)
        local gcc_includes=""
        gcc_includes="$(gcc_cxx_include_flags)"
        if [ -n "$gcc_includes" ]; then
          if [ -n "${CMAKE_CXX_FLAGS:-}" ]; then
            cmake_args+=( -DCMAKE_CXX_FLAGS="${gcc_includes} ${CMAKE_CXX_FLAGS}" )
          else
            cmake_args+=( -DCMAKE_CXX_FLAGS="${gcc_includes}" )
          fi
        fi
        ;;
    esac
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

    # TVM v0.22+ depends on tvm_ffi (vendored as a submodule).
    # Install it first so `import tvm` works in the self-check below.
    if [ -d "$tvm_dir/3rdparty/tvm-ffi/python" ]; then
      python -m pip install -e "$tvm_dir/3rdparty/tvm-ffi/python"
    elif [ -f "$tvm_dir/3rdparty/tvm-ffi/pyproject.toml" ] || [ -f "$tvm_dir/3rdparty/tvm-ffi/setup.py" ]; then
      python -m pip install -e "$tvm_dir/3rdparty/tvm-ffi"
    else
      log "Warning: tvm-ffi python package not found; tvm import may fail"
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
