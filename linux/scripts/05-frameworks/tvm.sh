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

detect_llvm_config() {
  if [ -n "${TVM_LLVM_CONFIG:-}" ]; then
    echo "$TVM_LLVM_CONFIG"
    return 0
  fi

  local candidates=(
    "llvm-config-22"
    "llvm-config-21"
    "llvm-config-20"
    "llvm-config-19"
    "llvm-config-18"
    "llvm-config"
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

sanitize_llvm_config_for_target() {
  local llvm_config_path="$1"
  local llvm_host_target=""
  local llvm_host_arch=""
  local target_arch=""

  [ -n "$llvm_config_path" ] || {
    printf '%s' ""
    return 0
  }

  if ! cross_build_is_active; then
    printf '%s' "$llvm_config_path"
    return 0
  fi

  target_arch="$(cross_target_arch 2>/dev/null || true)"
  llvm_host_target="$($llvm_config_path --host-target 2>/dev/null || true)"
  llvm_host_arch="$(arch_from_target_triple "$llvm_host_target" 2>/dev/null || true)"

  if [ -n "$target_arch" ] && [ -n "$llvm_host_arch" ] && [ "$llvm_host_arch" != "$target_arch" ]; then
    log "Disabling TVM LLVM for cross target ${target_arch}: ${llvm_config_path} reports host target ${llvm_host_target}, so it would link build-host LLVM archives into target binaries" >&2
    printf '%s' ""
    return 0
  fi

  printf '%s' "$llvm_config_path"
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

normalize_llvm_cmake_dir() {
  local dir="$1"
  local alt=""
  local config_path=""
  local resolved_dir=""

  [ -n "${dir}" ] || {
    printf '%s' ""
    return 0
  }

  config_path="$(readlink -f "${dir}/LLVMConfig.cmake" 2>/dev/null || true)"
  if [ -n "${config_path}" ] && [ -f "${config_path}" ]; then
    resolved_dir="$(dirname "${config_path}")"
    if [ "${resolved_dir}" != "${dir}" ]; then
      log "Normalizing LLVM CMake package path from ${dir} to ${resolved_dir}"
    fi
    printf '%s' "${resolved_dir}"
    return 0
  fi

  case "${dir}" in
    */lib64/cmake/llvm)
      alt="${dir%/lib64/cmake/llvm}/lib/cmake/llvm"
      ;;
    */lib/cmake/llvm)
      alt="${dir%/lib/cmake/llvm}/lib64/cmake/llvm"
      ;;
  esac

  config_path="$(readlink -f "${alt}/LLVMConfig.cmake" 2>/dev/null || true)"
  if [ -n "${alt}" ] && [ -n "${config_path}" ] && [ -f "${config_path}" ]; then
    resolved_dir="$(dirname "${config_path}")"
    log "Correcting LLVM CMake package path from ${dir} to ${resolved_dir}"
    printf '%s' "${resolved_dir}"
    return 0
  fi

  die "LLVM CMake package path is invalid: ${dir}"
}

detect_cross_llvm_cmake_dir() {
  local target_arch=""
  local dir=""

  if [ -n "${TVM_LLVM_DIR:-}" ]; then
    normalize_llvm_cmake_dir "${TVM_LLVM_DIR}"
    return 0
  fi

  if ! cross_build_is_active; then
    printf '%s' ""
    return 0
  fi

  target_arch="$(cross_target_arch 2>/dev/null || true)"
  [ -n "${target_arch}" ] || {
    printf '%s' ""
    return 0
  }

  if command -v llvm_cross_cmake_dir >/dev/null 2>&1; then
    dir="$(llvm_cross_cmake_dir "${target_arch}" 2>/dev/null || true)"
  fi

  if [ -n "${dir}" ]; then
    normalize_llvm_cmake_dir "${dir}"
    return 0
  fi

  if [ -z "${dir}" ] && command -v llvm_cross_install_prefix >/dev/null 2>&1; then
    local prefix=""
    prefix="$(llvm_cross_install_prefix "${target_arch}" 2>/dev/null || true)"
    for dir in \
      "${prefix}/lib/cmake/llvm" \
      "${prefix}/lib64/cmake/llvm"; do
      [ -f "${dir}/LLVMConfig.cmake" ] || continue
      normalize_llvm_cmake_dir "${dir}"
      return 0
    done
  fi

  printf '%s' "${dir}"
}

detect_vulkan_llvm_cmake_ignore_paths() {
  local prefix="${VULKAN_PREFIX:-/opt/vulkan}"
  local dir=""
  local out=""

  shopt -s nullglob
  for dir in \
    "${prefix}"/*/*/share/llvm/cmake \
    "${prefix}"/*/share/llvm/cmake; do
    [ -f "${dir}/LLVMConfig.cmake" ] || continue
    if [ -z "${out}" ]; then
      out="${dir}"
    else
      out="${out};${dir}"
    fi
  done
  shopt -u nullglob

  printf '%s' "${out}"
}

llvm_cmake_package_prefix() {
  case "$1" in
    */lib/cmake/llvm) printf '%s' "${1%/lib/cmake/llvm}" ;;
    */lib64/cmake/llvm) printf '%s' "${1%/lib64/cmake/llvm}" ;;
    *) return 1 ;;
  esac
}

llvm_cmake_package_has_umbrella_lib() {
  local prefix="$1"
  local candidate

  for candidate in \
    "${prefix}/lib/libLLVM.so" \
    "${prefix}/lib/libLLVM.a" \
    "${prefix}/lib64/libLLVM.so" \
    "${prefix}/lib64/libLLVM.a"; do
    [ -e "${candidate}" ] || continue
    return 0
  done

  return 1
}

validate_detected_llvm_cmake_package() {
  local llvm_dir="$1"
  local prefix llvm_config_file

  [ -n "${llvm_dir}" ] || return 0
  llvm_dir="$(normalize_llvm_cmake_dir "${llvm_dir}")"
  prefix="$(llvm_cmake_package_prefix "${llvm_dir}" 2>/dev/null || true)"
  [ -n "${prefix}" ] || return 0

  llvm_config_file="${llvm_dir}/LLVMConfig.cmake"
  [ -f "${llvm_config_file}" ] || die "LLVMConfig.cmake missing at ${llvm_config_file}"
  if ! llvm_cmake_package_has_umbrella_lib "${prefix}"; then
    log "Sanitizing target LLVM CMake package: missing umbrella libLLVM under ${prefix}"
    sanitize_llvm_cmake_package_for_missing_umbrella_lib "${prefix}" "${llvm_dir}"
  fi
  llvm_cmake_package_has_component_metadata "${llvm_config_file}" || \
    die "Target LLVM package at ${llvm_dir} does not provide LLVM component metadata"
}

detect_llvm_major_version() {
  local llvm_config_path="$1"
  local llvm_dir="${2:-}"
  local major=""
  local llvm_release=""

  if [ -n "${llvm_dir}" ] && cross_build_is_active; then
    # linux/Dockerfile.toolchain pins both host and cross LLVM installs from the
    # same LLVM_RELEASE, so in cross mode the target package should follow that
    # pinned release rather than the build-host llvm-config.
    if declare -F llvm_release_version >/dev/null 2>&1; then
      llvm_release="$(llvm_release_version 2>/dev/null || true)"
    elif [ -n "${LLVM_RELEASE:-}" ]; then
      llvm_release="${LLVM_RELEASE}"
    fi
    if [ -n "${llvm_release}" ]; then
      major="$(version_major "${llvm_release}" 2>/dev/null || true)"
    fi
  fi

  if [ -z "${major}" ] && [ -n "${llvm_dir}" ]; then
    major="$(detect_llvm_major_version_from_cmake_package "${llvm_dir}" 2>/dev/null || true)"
  fi

  if [ -z "${major}" ] && [ -n "${llvm_config_path}" ] && command -v "${llvm_config_path}" >/dev/null 2>&1; then
    major="$(${llvm_config_path} --version 2>/dev/null | cut -d. -f1 || true)"
  fi

  if [ -z "${major}" ] && [ -n "${LLVM_RELEASE:-}" ]; then
    major="$(version_major "${LLVM_RELEASE}")"
  fi

  printf '%s' "${major}"
}

detect_llvm_major_version_from_metadata_file() {
  local metadata_file="$1"
  local line=""

  [ -f "${metadata_file}" ] || return 1

  while IFS= read -r line; do
    case "${line}" in
      *LLVM_VERSION_MAJOR* )
        if [[ "${line}" =~ LLVM_VERSION_MAJOR[^0-9]*([0-9]+) ]]; then
          printf '%s' "${BASH_REMATCH[1]}"
          return 0
        fi
        ;;
      *LLVM_PACKAGE_VERSION*|*PACKAGE_VERSION* )
        if [[ "${line}" =~ (LLVM_PACKAGE_VERSION|PACKAGE_VERSION)[^0-9]*([0-9]+) ]]; then
          printf '%s' "${BASH_REMATCH[2]}"
          return 0
        fi
        ;;
    esac
  done < "${metadata_file}"

  return 1
}

detect_llvm_major_version_from_cmake_package() {
  local llvm_dir="$1"
  local prefix=""
  local candidate=""
  local major=""

  [ -n "${llvm_dir}" ] || return 1

  for candidate in \
    "${llvm_dir}/LLVMConfigVersion.cmake" \
    "${llvm_dir}/LLVMConfig.cmake"; do
    major="$(detect_llvm_major_version_from_metadata_file "${candidate}" 2>/dev/null || true)"
    if [ -n "${major}" ]; then
      printf '%s' "${major}"
      return 0
    fi
  done

  prefix="$(llvm_cmake_package_prefix "${llvm_dir}" 2>/dev/null || true)"
  if [ -z "${prefix}" ]; then
    return 1
  fi

  for candidate in \
    "${prefix}/include/llvm/Config/llvm-config.h" \
    "${prefix}/include/llvm/Config/llvm-config.h.cmake"; do
    major="$(detect_llvm_major_version_from_metadata_file "${candidate}" 2>/dev/null || true)"
    if [ -n "${major}" ]; then
      printf '%s' "${major}"
      return 0
    fi
  done

  return 1
}

patch_tvm_findllvm_for_cross_package() {
  local tvm_dir="$1"
  local llvm_dir="$2"
  local findllvm_cmake="${tvm_dir}/cmake/utils/FindLLVM.cmake"

  [ -n "${llvm_dir}" ] || return 0
  [ -f "${findllvm_cmake}" ] || return 0

  if grep -q 'Prefer LLVM_AVAILABLE_LIBS from CONFIG package' "${findllvm_cmake}"; then
    return 0
  fi

  log "Patching TVM FindLLVM.cmake to keep cross LLVM CONFIG packages"
  python3 - "${findllvm_cmake}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''    llvm_map_components_to_libnames(LLVM_LIBS "all")
    if (NOT LLVM_LIBS)
      message(STATUS "Not found - LLVM_LIBS")
      message(STATUS "Fall back to using llvm-config")
      set(LLVM_CONFIG "${LLVM_TOOLS_BINARY_DIR}/llvm-config")
    endif()'''
new = '''    llvm_map_components_to_libnames(LLVM_LIBS "all")
    if (NOT LLVM_LIBS AND DEFINED LLVM_AVAILABLE_LIBS AND LLVM_AVAILABLE_LIBS)
      # Prefer LLVM_AVAILABLE_LIBS from CONFIG package when stripped cross installs
      # do not populate llvm_map_components_to_libnames(all).
      set(LLVM_LIBS ${LLVM_AVAILABLE_LIBS})
      message(STATUS "Using LLVM_AVAILABLE_LIBS from LLVM CONFIG package")
    endif()
    if (NOT LLVM_LIBS)
      message(STATUS "Not found - LLVM_LIBS")
      message(STATUS "Fall back to using llvm-config")
      set(LLVM_CONFIG "${LLVM_TOOLS_BINARY_DIR}/llvm-config")
    endif()'''
if old not in text:
    raise SystemExit('expected LLVM CONFIG block not found')
path.write_text(text.replace(old, new, 1))
PY

  grep -q 'Prefer LLVM_AVAILABLE_LIBS from CONFIG package' "${findllvm_cmake}" || \
    die "Failed to patch TVM FindLLVM.cmake for cross LLVM CONFIG packages"
}

require_toolchain_python() {
  local python_mm="${PYTHON_MAJOR_MINOR:-}"
  local python_bin=""

  if [ -z "$python_mm" ] && command -v host_python_major_minor >/dev/null 2>&1; then
    python_mm="$(host_python_major_minor 2>/dev/null || true)"
  fi

  if [ -z "$python_mm" ]; then
    die "PYTHON_MAJOR_MINOR is not set; cannot resolve the source-built toolchain Python"
  fi

  python_bin="/usr/local/bin/python${python_mm}"
  if [ ! -x "$python_bin" ]; then
    die "Expected source-built toolchain Python at ${python_bin}; TVM must use the interpreter from linux/Dockerfile.toolchain"
  fi

  printf '%s' "$python_bin"
}

tvm_cross_wheel_platform_tag() {
  cross_wheel_platform_tag
}

cross_linker_search_flags() {
  local triplet=""
  local flags=""
  local dir

  if ! cross_build_is_active; then
    printf '%s' ""
    return 0
  fi

  triplet="$(cross_target_triplet 2>/dev/null || true)"
  [ -n "${triplet}" ] || {
    printf '%s' ""
    return 0
  }

  for dir in \
    "/usr/lib/${triplet}" \
    "/lib/${triplet}" \
    "/usr/${triplet}/lib"; do
    [ -d "${dir}" ] || continue
    flags="${flags:+${flags} }-L${dir}"
  done

  printf '%s' "${flags}"
}


append_tvm_cmake_args() {
  local out_name="$1"
  local python_module="$2"
  local build_type="$3"
  local desired_cc="$4"
  local desired_cxx="$5"
  local llvm_cmake_value="$6"
  local llvm_dir="$7"
  local llvm_ignore_paths="$8"
  local use_vulkan="$9"
  local spirv_tools_lib="${10:-}"
  local cross_link_flags="${11:-}"
  local -n out_ref="${out_name}"

  out_ref+=(
    -DCMAKE_BUILD_TYPE="$build_type"
    -DUSE_OPENCL=OFF
    -DUSE_CUDA=OFF
    "-DTVM_BUILD_PYTHON_MODULE=${python_module}"
  )

  if cross_build_is_active; then
    append_cmake_cross_args "${out_name}"
    out_ref+=( -DUSE_ALTERNATIVE_LINKER=OFF )
    if [ -n "${cross_link_flags:-}" ]; then
      out_ref+=(
        "-DCMAKE_EXE_LINKER_FLAGS=${cross_link_flags}${CMAKE_EXE_LINKER_FLAGS:+ ${CMAKE_EXE_LINKER_FLAGS}}"
        "-DCMAKE_SHARED_LINKER_FLAGS=${cross_link_flags}${CMAKE_SHARED_LINKER_FLAGS:+ ${CMAKE_SHARED_LINKER_FLAGS}}"
        "-DCMAKE_MODULE_LINKER_FLAGS=${cross_link_flags}${CMAKE_MODULE_LINKER_FLAGS:+ ${CMAKE_MODULE_LINKER_FLAGS}}"
      )
    fi
  fi

  if [ -n "${llvm_dir}" ]; then
    out_ref+=( -DLLVM_DIR="${llvm_dir}" )
    if [ -n "${llvm_ignore_paths}" ]; then
      out_ref+=( "-DCMAKE_IGNORE_PATH=${llvm_ignore_paths}${CMAKE_IGNORE_PATH:+;${CMAKE_IGNORE_PATH}}" )
    fi
  fi

  out_ref+=(
    -DCMAKE_C_COMPILER="$desired_cc"
    -DCMAKE_CXX_COMPILER="$desired_cxx"
  )

  if [ "$use_vulkan" -eq 1 ]; then
    out_ref+=( -DUSE_VULKAN=ON )
    if [ -n "${spirv_tools_lib:-}" ]; then
      out_ref+=( -DVulkan_SPIRV_TOOLS_LIBRARY="${spirv_tools_lib}" )
    fi
  else
    out_ref+=( -DUSE_VULKAN=OFF )
  fi

  out_ref+=( -DUSE_LLVM="$llvm_cmake_value" )
}

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/tvm-llvm-compat.sh"


patch_tvm_for_llvm_22() {
  local tvm_dir="$1"
  local llvm_config_path="$2"
  local llvm_dir="${3:-}"
  local llvm_major=""

  llvm_major="$(detect_llvm_major_version "$llvm_config_path" "$llvm_dir")"
  case "$llvm_major" in
    22|2[3-9]|[3-9][0-9]) ;;
    *) return 0 ;;
  esac

  local llvm_instance_cc="$tvm_dir/src/target/llvm/llvm_instance.cc"
  [ -f "$llvm_instance_cc" ] || return 0

  if grep -q 'lookupTarget(triple_obj, error)' "$llvm_instance_cc"; then
    log "TVM LLVM 22 patch already present in $llvm_instance_cc"
    return 0
  fi

  log "Patching TVM for LLVM $llvm_major compatibility"
  python3 - "$llvm_instance_cc" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = [
    (r'llvm::StringMap<llvm::cl::Option\*>& options = llvm::cl::getRegisteredOptions\(\);',
     r'auto& options = llvm::cl::getRegisteredOptions();'),
    (r'if \(options\.count\(opt\.name\)\) \{',
     r'if (options.find(opt.name) != options.end()) {'),
    (r'llvm::cl::Option\* base_op = options\[opt->name\];',
     r'llvm::cl::Option* base_op = nullptr;\n  auto it = options.find(opt->name);\n  if (it != options.end()) {\n    base_op = it->second;\n  }\n  if (base_op == nullptr) {\n    opt->type = Option::OptType::Invalid;\n    return;\n  }'),
    (r'llvm::cl::Option\* base_op = options\[new_opt\.name\];',
     r'llvm::cl::Option* base_op = nullptr;\n    auto it = options.find(new_opt.name);\n    if (it != options.end()) {\n      base_op = it->second;\n    }\n    ICHECK(base_op != nullptr) << "LLVM option not found: " << new_opt.name;'),
    (r'\n  target_options_\.UnsafeFPMath = false;', ''),
    (r'const llvm::Target\* llvm_instance = llvm::TargetRegistry::lookupTarget\(triple, error\);',
     r'llvm::Triple triple_obj(triple);\n  const llvm::Target* llvm_instance = llvm::TargetRegistry::lookupTarget(triple_obj, error);'),
    (r'llvm::TargetMachine\* tm = llvm_instance->createTargetMachine\(\n      triple, cpu, features, target_options, reloc_model, code_model, opt_level\);',
     r'llvm::Triple triple_obj(triple);\n  llvm::TargetMachine* tm = llvm_instance->createTargetMachine(\n      triple_obj, cpu, features, target_options, reloc_model, code_model, opt_level);'),
]

for pattern, replacement in replacements:
    if not re.search(pattern, text, re.DOTALL):
        continue
    text = re.sub(pattern, replacement, text, count=1)

path.write_text(text)
PY

  grep -q 'lookupTarget(triple_obj, error)' "$llvm_instance_cc" || \
    die "Failed to patch TVM for LLVM 22: lookupTarget update missing"
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

try_source_vulkan_env() {
  source_vulkan_sdk_env "${VULKAN_PREFIX:-/opt/vulkan}" sanitize-libs
}

main() {
  local workdir="${TVM_WORKDIR:-$(pick_default_workdir)}"
  local ref="${TVM_REF:-main}"
  local build_type="${TVM_BUILD_TYPE:-Release}"
  local llvm_config="${TVM_LLVM_CONFIG:-}"
  local llvm_dir="${TVM_LLVM_DIR:-}"
  local llvm_ignore_paths=""
  local prefix="${TVM_PREFIX:-}"
  local use_vulkan="${TVM_USE_VULKAN:-1}"
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

  patch_tvm_for_llvm_22 "$tvm_dir" "$llvm_config" "$llvm_dir"
  patch_tvm_findllvm_for_cross_package "$tvm_dir" "$llvm_dir"

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

    if [ -z "$spirv_tools_lib" ]; then
      die "Vulkan enabled but SPIRV-Tools library not found under /opt/vulkan. Install the Vulkan SDK so it provides libSPIRV-Tools."
    fi
    if ! is_under_opt_vulkan "$spirv_tools_lib"; then
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
    "$spirv_tools_lib" \
    "$cross_link_flags"

  cmake -S "$tvm_dir" -B "$build_dir" "${cmake_args[@]}"

  log "Building TVM (jobs=$jobs, mb_per_job=$mb_per_job)"
  cmake --build "$build_dir" --parallel "$jobs"

  log "Installing TVM to $prefix"
  cmake --install "$build_dir"

  if [ "$do_python" -eq 1 ]; then
    log "Setting up Python venv + TVM Python package"
    HOST_PYTHON="$(require_toolchain_python)"
    uv venv --seed "$tvm_dir/.venv" --python="$HOST_PYTHON"
    # shellcheck disable=SC1091
    source "$tvm_dir/.venv/bin/activate"
    local venv_python="${VIRTUAL_ENV}/bin/python"
    export UV_PYTHON="${VIRTUAL_ENV}/bin/python" \
           MEDIA_HOST_PYTHON="${VIRTUAL_ENV}/bin/python"

    uv pip install -U pip setuptools wheel build scikit-build-core cython setuptools-scm
    uv pip install -U numpy cloudpickle decorator psutil scipy attrs

    local TVM_WHEEL_DIR="${prefix}/wheels"
    local -a wheel_cmake_args=()
    local wheel_cmake_args_string
    mkdir -p "$TVM_WHEEL_DIR"
    # Avoid stale wheel artifacts from previous runs influencing install/retag.
    rm -f "${TVM_WHEEL_DIR}"/*.whl

    append_tvm_cmake_args \
      wheel_cmake_args \
      ON \
      "$build_type" \
      "$desired_cc" \
      "$desired_cxx" \
      "$llvm_cmake_value" \
      "$llvm_dir" \
      "$llvm_ignore_paths" \
      "$use_vulkan" \
      "$spirv_tools_lib" \
      "$cross_link_flags"

    wheel_cmake_args_string="$(shell_quote_args "${wheel_cmake_args[@]}")"

    if cross_build_is_active; then
      local wheel_platform

      wheel_platform="$(tvm_cross_wheel_platform_tag || true)"
      if [ -z "$wheel_platform" ]; then
        log "Skipping TVM wheel build in cross mode; unsupported target architecture $(cross_target_arch 2>/dev/null || echo unknown)"
      elif [ -f "$tvm_dir/pyproject.toml" ]; then
        log "Building cross TVM wheel into $TVM_WHEEL_DIR"
        if CMAKE_GENERATOR=Ninja \
          CMAKE_ARGS="${wheel_cmake_args_string}" \
          "$venv_python" -m build --wheel --no-isolation \
            --outdir "$TVM_WHEEL_DIR" \
            -Cbuild-dir="${tvm_dir}/build-wheel-${wheel_platform}" \
            "$tvm_dir"; then
          shopt -s nullglob
          local -a built_cross_wheels=("${TVM_WHEEL_DIR}"/*.whl)
          shopt -u nullglob
          if [ "${#built_cross_wheels[@]}" -eq 0 ]; then
            log "Warning: cross TVM wheel build succeeded but produced no wheel artifact"
          else
            local cross_wheel
            for cross_wheel in "${built_cross_wheels[@]}"; do
              log "Retagging cross TVM wheel for ${wheel_platform}: $(basename "${cross_wheel}")"
              "$venv_python" -m wheel tags --remove --platform-tag="${wheel_platform}" "${cross_wheel}" || \
                log "Warning: failed to retag cross TVM wheel $(basename "${cross_wheel}")"
            done
          fi
        else
          log "Warning: cross TVM wheel build failed"
        fi
      else
        log "TVM python packaging not detected for wheel build; skipped"
      fi
    else
      if [ -f "$tvm_dir/pyproject.toml" ]; then
        log "Building TVM wheel into $TVM_WHEEL_DIR"
        CMAKE_GENERATOR=Ninja \
        CMAKE_ARGS="${wheel_cmake_args_string}" \
        "$venv_python" -m build --wheel --no-isolation \
          --outdir "$TVM_WHEEL_DIR" \
          -Cbuild-dir="${tvm_dir}/build-wheel-native" \
          "$tvm_dir" || log "Warning: TVM wheel build failed"
      else
        log "TVM python packaging not detected for wheel build; skipped"
      fi

      if [ -f "$tvm_dir/3rdparty/tvm-ffi/pyproject.toml" ]; then
        log "Installing Apache TVM FFI Python package from source tree"
        uv pip install "$tvm_dir/3rdparty/tvm-ffi"
      else
        log "Local Apache TVM FFI package not found; relying on apache-tvm-ffi from the Python package resolver"
      fi

      shopt -s nullglob
      local -a built_wheels=("${TVM_WHEEL_DIR}"/*.whl)
      shopt -u nullglob

      if [ "${#built_wheels[@]}" -gt 0 ]; then
        log "Installing TVM Python wheel ${built_wheels[0]}"
        uv pip install "${built_wheels[0]}"
      else
        log "Wheel build unavailable; installing TVM Python package from source tree"
        uv pip install "$tvm_dir"
      fi

      # Newer tvm_ffi imports pull in tvm_ffi.testing during `import tvm`, which
      # expects pytest in the build venv for this sanity check.
      uv pip install -U pytest

      "$venv_python" - <<'PY'
import tvm
print("tvm imported OK; version=", tvm.__version__)
PY
    fi
  else
    log "Skipping Python setup (--no-python)"
  fi

  log "Done. Build dir: $build_dir"
  log "Install prefix: $prefix"
}

main "$@"
