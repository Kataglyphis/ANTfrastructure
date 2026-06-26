#!/usr/bin/env bash
# llvm-cross.sh — LLVM cross-compilation build functions.
# Sourced by llvm.sh; not executed standalone.
[ -n "${_LLVM_CROSS_SH_LOADED:-}" ] && return 0
_LLVM_CROSS_SH_LOADED=1
set -euo pipefail

install_cross_llvm_target_packages() {
  local target_label="$1"

  [ "${target_label}" = "amd64" ] && return 0
  command -v install_target_packages >/dev/null 2>&1 || die "install_target_packages is unavailable; cross-env.sh must be sourced before llvm.sh"

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    install_target_packages \
      zlib1g-dev \
      libzstd-dev \
      libxml2-dev
  )
}

_build_llvm_cross_core() {
  local mode="$1"
  local target_label="$2"
  local triplet backend prefix release tag source_root build_root source_dir build_dir
  local wrapper_dir native_wrapper_dir jobs native_tool_dir
  local build_cc build_cxx build_cc_real build_cxx_real host_path
  local target_runtime_link_path linker_flags_init link_dir clang_triple

  [ -n "${target_label}" ] || die "_build_llvm_cross_core: target architecture required"
  target_label="$(arch_normalize "${target_label}")"
  [ "${target_label}" = "amd64" ] && { log "Skipping cross LLVM build for amd64 (host already serves)"; return 0; }

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || die "No triplet for ${target_label}"

  case "${mode}" in
    target-llvm)
      prefix="$(llvm_cross_install_prefix "${target_label}")" || die "Unable to resolve LLVM cross install prefix for ${target_label}"
      release="$(llvm_release_version)"
      tag="$(llvm_git_tag)"
      build_dir_suffix="${triplet}"
      wrapper_dir_suffix="${triplet}-tool-bin"
      ;;
    target-clang)
      prefix="/opt/llvm-target"
      release="${LLVM_RELEASE:-22.1.6}"
      tag="llvmorg-${release}"
      build_dir_suffix="target-clang-${target_label}"
      wrapper_dir_suffix="target-clang-${target_label}-tool-bin"
      ;;
    *) die "Unknown LLVM cross build mode: ${mode}" ;;
  esac

  backend="$(llvm_cross_backend "${target_label}")" || die "No LLVM backend for ${target_label}"
  source_root="${LLVM_CROSS_SOURCE_ROOT:-/var/cache/llvm-src}"
  build_root="${LLVM_CROSS_BUILD_ROOT:-/var/tmp/llvm-cross-build}"
  source_dir="${source_root}/llvm-project-${release}"
  build_dir="${build_root}/${build_dir_suffix}"
  wrapper_dir="${build_root}/${wrapper_dir_suffix}"
  jobs="$(compute_jobs_with_mem_cap "${LLVM_CROSS_JOBS:-}" "${LLVM_CROSS_MB_PER_JOB:-3500}")"

  # --- Early-return if already installed ---
  case "${mode}" in
    target-llvm)
      local cmake_dir
      if cmake_dir="$(llvm_cross_cmake_dir "${target_label}" 2>/dev/null || true)"; then
        if [ -n "${cmake_dir}" ] && llvm_cross_install_looks_complete "${target_label}"; then
          validate_cross_llvm_cmake_package "${target_label}"
          log "Reusing target LLVM install for ${target_label}: ${cmake_dir}"
          return 0
        fi
        log "Discarding incomplete target LLVM install for ${target_label}: ${prefix}"
        rm -rf "${prefix}"
      fi
      ;;
    target-clang)
      if [ -x "${prefix}/bin/clang" ]; then
        local installed_version
        installed_version="$("${prefix}/bin/clang" --version 2>/dev/null | awk 'NR==1{print $NF}' || true)"
        if [ "${installed_version}" = "${release}" ]; then
          log "Target clang ${release} for ${target_label} already installed at ${prefix}"
          return 0
        fi
        log "Replacing existing target clang at ${prefix} (wanted ${release}, found ${installed_version})"
        rm -rf "${prefix}"
      fi
      ;;
  esac

  # --- Source retrieval ---
  mkdir -p "${source_root}" "${build_root}"
  if [ ! -d "${source_dir}/.git" ]; then
    rm -rf "${source_dir}"
    log "Cloning llvm-project ${tag} for ${mode} ${target_label}"
    git clone --depth 1 --branch "${tag}" https://github.com/llvm/llvm-project.git "${source_dir}"
  fi

  # --- Mode-specific pre-build hooks ---
  case "${mode}" in
    target-llvm)
      patch_cross_llvm_config_template "${source_dir}"
      ;;
    target-clang)
      native_wrapper_dir="${build_root}/target-clang-${target_label}-native-tool-bin"
      build_cc_real="$(resolve_build_gcc_tool gcc 2>/dev/null || command -v gcc 2>/dev/null || true)"
      build_cxx_real="$(resolve_build_gcc_tool g++ 2>/dev/null || command -v g++ 2>/dev/null || true)"
      [ -n "${build_cc_real}" ] || die "Host C compiler not found for LLVM native helper tools"
      [ -n "${build_cxx_real}" ] || die "Host C++ compiler not found for LLVM native helper tools"
      host_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ;;
  esac

  native_tool_dir="$(llvm_host_native_tool_dir)" || die "Host LLVM native tools not found"

  rm -rf "${prefix}" "${build_dir}" "${wrapper_dir}" ${native_wrapper_dir:+"${native_wrapper_dir}"}
  log "Building LLVM ${release} for ${target_label} (${triplet}) in ${mode} mode — this will take a while"

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    export CCACHE_DIR="/var/cache/ccache"
    export SCCACHE_DIR="/var/cache/sccache"
    setup_linux_cross_env
    llvm_cross_populate_tool_wrapper_dir "${wrapper_dir}"

    case "${mode}" in
      target-clang)
        build_cc="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-gcc" "${build_cc_real}" "${host_path}")"
        build_cxx="$(make_host_compiler_wrapper "${native_wrapper_dir}/host-g++" "${build_cxx_real}" "${host_path}")"
        target_runtime_link_path="$(llvm_cross_target_runtime_library_path "${target_label}" || true)"
        linker_flags_init=""
        if [ -n "${target_runtime_link_path}" ]; then
          for link_dir in ${target_runtime_link_path//:/ }; do
            [ -d "${link_dir}" ] || continue
            linker_flags_init="${linker_flags_init:+${linker_flags_init} }-Wl,-rpath-link,${link_dir}"
          done
        fi
        ;;
    esac

    clang_triple="${triplet}"
    case "${target_label}" in
      arm64) clang_triple="aarch64-unknown-linux-gnu" ;;
      riscv64) clang_triple="riscv64-unknown-linux-gnu" ;;
    esac
    export PATH="${wrapper_dir}:${PATH}"

    local -a extra_cmake_args=()
    if command -v ccache >/dev/null 2>&1; then
      extra_cmake_args+=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      )
    elif command -v sccache >/dev/null 2>&1; then
      extra_cmake_args+=(
        -DCMAKE_C_COMPILER_LAUNCHER=sccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=sccache
      )
    fi

    local -a linker_flag_args=()
    case "${mode}" in
      target-clang)
        if [ -n "${linker_flags_init}" ]; then
          linker_flag_args+=(
            "-DCMAKE_EXE_LINKER_FLAGS_INIT=${linker_flags_init}"
            "-DCMAKE_SHARED_LINKER_FLAGS_INIT=${linker_flags_init}"
            "-DCMAKE_MODULE_LINKER_FLAGS_INIT=${linker_flags_init}"
          )
        fi
        ;;
    esac

    local -a mode_specific_args=()
    case "${mode}" in
      target-llvm)
        mode_specific_args=(
          -DLLVM_ENABLE_PROJECTS=
          -DLLVM_ENABLE_RUNTIMES=
        )
        ;;
      target-clang)
        mode_specific_args=(
          -DLLVM_BINUTILS_INCDIR=/usr/include
          -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"
          -DLLVM_ENABLE_RUNTIMES="compiler-rt"
          -DCOMPILER_RT_BUILD_SANITIZERS=ON
          -DCOMPILER_RT_BUILD_BUILTINS=ON
          -DCOMPILER_RT_BUILD_XRAY=OFF
          -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
          -DCOMPILER_RT_BUILD_PROFILE=ON
          -DCOMPILER_RT_BUILD_MEMPROF=OFF
          -DCOMPILER_RT_BUILD_ORC=OFF
          -DCOMPILER_RT_BUILD_GWP_ASAN=OFF
          -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
          -DSANITIZER_CXX_ABI=libstdc++
          -DLLVM_USE_HOST_TOOLS=ON
          "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${build_cc};-DCMAKE_CXX_COMPILER=${build_cxx};-DCMAKE_ASM_COMPILER=${build_cc}"
          -DCLANG_TABLEGEN="${native_tool_dir}/clang-tblgen"
        )
        ;;
    esac

    cmake -G Ninja \
      "${extra_cmake_args[@]}" \
      -S "${source_dir}/llvm" \
      -B "${build_dir}" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_SYSTEM_NAME=Linux \
      -DCMAKE_SYSTEM_PROCESSOR="${CROSS_TARGET_PROCESSOR}" \
      -DCMAKE_SYSROOT="${CMAKE_SYSROOT:-/}" \
      -DCMAKE_C_COMPILER="${CC}" \
      -DCMAKE_CXX_COMPILER="${CXX}" \
      -DCMAKE_ASM_COMPILER="${CC}" \
      -DCMAKE_AR="${AR}" \
      -DCMAKE_RANLIB="${RANLIB}" \
      -DCMAKE_NM="${NM}" \
      -DCMAKE_OBJCOPY="${OBJCOPY}" \
      -DCMAKE_STRIP="${STRIP}" \
      "${linker_flag_args[@]}" \
      -DCMAKE_C_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_CXX_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_ASM_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_LIBRARY_ARCHITECTURE="${CROSS_TARGET_TRIPLET}" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
      -DCMAKE_INSTALL_PREFIX="${prefix}" \
      -DLLVM_HOST_TRIPLE="${clang_triple}" \
      -DLLVM_DEFAULT_TARGET_TRIPLE="${clang_triple}" \
      -DLLVM_TARGETS_TO_BUILD="${backend}" \
      "${mode_specific_args[@]}" \
      -DLLVM_BUILD_LLVM_DYLIB=ON \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLVM_INCLUDE_TOOLS=ON \
      -DLLVM_BUILD_TOOLS=ON \
      -DLLVM_TOOL_LLVM_SHLIB_BUILD=ON \
      -DLLVM_INCLUDE_UTILS=OFF \
      -DLLVM_BUILD_UTILS=OFF \
      -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_INCLUDE_BENCHMARKS=OFF \
      -DLLVM_INCLUDE_EXAMPLES=OFF \
      -DLLVM_INCLUDE_DOCS=OFF \
      -DLLVM_ENABLE_TERMINFO=OFF \
      -DLLVM_ENABLE_LIBEDIT=OFF \
      -DLLVM_ENABLE_ASSERTIONS=OFF \
      -DLLVM_ENABLE_WARNINGS=OFF \
      -DLLVM_NATIVE_TOOL_DIR="${native_tool_dir}" \
      -DLLVM_TABLEGEN="${native_tool_dir}/llvm-tblgen"

    cmake --build "${build_dir}" --parallel "${jobs}"

    case "${mode}" in
      target-llvm)
        cmake --build "${build_dir}" --parallel "${jobs}" --target llvm-config
        ;;
    esac

    cmake --install "${build_dir}"
  )

  # --- Mode-specific post-build hooks ---
  case "${mode}" in
    target-llvm)
      install_cross_llvm_config_binary "${target_label}" "${build_dir}"
      cmake_dir="$(llvm_cross_cmake_dir "${target_label}")" || die "Target LLVM CMake package missing after install for ${target_label}"
      validate_cross_llvm_cmake_package "${target_label}"
      log "Installed target LLVM package for ${target_label}: ${cmake_dir}"
      ;;
    target-clang)
      if [ -x "${prefix}/bin/clang" ]; then
        log "Target clang ${release} for ${target_label} installed at ${prefix}"
      else
        die "Target clang build for ${target_label} completed but ${prefix}/bin/clang not found"
      fi
      ;;
  esac
}

build_cross_llvm_target() {
  _build_llvm_cross_core target-llvm "$1"
}

install_target_clang_toolchain() {
  _build_llvm_cross_core target-clang "${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
}

build_cross_llvm_targets() {
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local target target_label

  cross_mode_requested || return 0
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || die "Unsupported LLVM cross target list: ${targets_raw}"

  for target in ${targets_raw//,/ }; do
    target_label="$(arch_normalize "${target}")"
    case "${target_label}" in
      amd64|arm64|riscv64) ;;
      *)
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
      ;;
    esac

    [ "${target_label}" = "amd64" ] && continue
    install_cross_llvm_target_packages "${target_label}"
    build_cross_llvm_target "${target_label}"
  done
}
