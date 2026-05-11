#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain

llvm_cross_triplet() {
  case "$1" in
    arm64|aarch64) printf '%s' "aarch64-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    amd64|x86_64) printf '%s' "x86_64-linux-gnu" ;;
    *) return 1 ;;
  esac
}

llvm_canonical_cross_target() {
  case "$1" in
    amd64|x86_64) printf '%s' "amd64" ;;
    arm64|aarch64) printf '%s' "arm64" ;;
    riscv64) printf '%s' "riscv64" ;;
    *) return 1 ;;
  esac
}

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

install_cross_clang_wrappers() {
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local gcc_prefix target target_label triplet sysroot wrapper

  [ "${BUILD_MODE:-native}" = "cross" ] || return 0

  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  [ -d "${gcc_prefix}" ] || gcc_prefix="/usr"

  for target in ${targets_raw//,/ }; do
    target_label="$(llvm_canonical_cross_target "$target")" || {
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
    }
    triplet="$(llvm_cross_triplet "$target_label")" || {
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
    }
    if [ "${target_label}" = "amd64" ]; then
      sysroot="/"
    else
      sysroot="/usr/${triplet}"
      [ -d "${sysroot}" ] || die "Expected cross sysroot not found for ${target_label}: ${sysroot}"
    fi

    wrapper="/usr/local/bin/clang-${target_label}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/clang --target=${triplet} --sysroot=${sysroot} --gcc-toolchain=${gcc_prefix} "\$@"
EOF
    chmod +x "${wrapper}"
    log "Installed LLVM wrapper: $(basename "${wrapper}")"

    wrapper="/usr/local/bin/clang++-${target_label}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/clang++ --target=${triplet} --sysroot=${sysroot} --gcc-toolchain=${gcc_prefix} "\$@"
EOF
    chmod +x "${wrapper}"
    log "Installed LLVM wrapper: $(basename "${wrapper}")"
  done
}

llvm_cross_backend() {
  case "$1" in
    amd64|x86_64) printf '%s' "X86" ;;
    arm64|aarch64) printf '%s' "AArch64" ;;
    riscv64) printf '%s' "RISCV" ;;
    *) return 1 ;;
  esac
}

llvm_release_version() {
  if [ -n "${LLVM_RELEASE:-}" ]; then
    printf '%s' "${LLVM_RELEASE}"
    return 0
  fi

  case "${LLVM_WANTED:-${CLANG_WANTED:-22}}" in
    22) printf '%s' "22.1.4" ;;
    *) printf '%s' "${LLVM_WANTED:-${CLANG_WANTED:-22}}.1.0" ;;
  esac
}

llvm_git_tag() {
  printf '%s' "llvmorg-$(llvm_release_version)"
}

llvm_cross_root() {
  printf '%s' "${LLVM_CROSS_ROOT:-/opt/llvm-cross}"
}

llvm_cross_install_prefix() {
  local triplet

  triplet="$(llvm_cross_triplet "$1")" || return 1
  printf '%s' "$(llvm_cross_root)/${triplet}"
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

llvm_cross_include_dir() {
  local prefix

  prefix="$(llvm_cross_install_prefix "$1")" || return 1
  [ -d "${prefix}/include" ] || return 1
  printf '%s' "${prefix}/include"
}

llvm_host_native_tool_dir() {
  local major="${LLVM_WANTED:-${CLANG_WANTED:-22}}"
  local candidate

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

build_cross_llvm_target() {
  local target_label="$1"
  local triplet backend prefix cmake_dir native_tool_dir release tag
  local source_root build_root source_dir build_dir jobs wrapper_dir tool

  [ "${target_label}" = "amd64" ] && return 0

  triplet="$(llvm_cross_triplet "${target_label}")" || die "Unsupported LLVM cross target: ${target_label}"
  backend="$(llvm_cross_backend "${target_label}")" || die "Unsupported LLVM backend target: ${target_label}"
  prefix="$(llvm_cross_install_prefix "${target_label}")" || die "Unable to resolve LLVM cross install prefix for ${target_label}"
  if cmake_dir="$(llvm_cross_cmake_dir "${target_label}" 2>/dev/null || true)"; then
    if [ -n "${cmake_dir}" ]; then
      log "Reusing target LLVM install for ${target_label}: ${cmake_dir}"
      return 0
    fi
  fi

  native_tool_dir="$(llvm_host_native_tool_dir)" || die "Native LLVM host tools not found; expected llvm-tblgen from the host LLVM install"
  release="$(llvm_release_version)"
  tag="$(llvm_git_tag)"
  source_root="${LLVM_CROSS_SOURCE_ROOT:-/var/tmp/llvm-cross-src}"
  build_root="${LLVM_CROSS_BUILD_ROOT:-/var/tmp/llvm-cross-build}"
  source_dir="${source_root}/llvm-project-${release}"
  build_dir="${build_root}/${triplet}"
  wrapper_dir="${build_root}/${triplet}-tool-bin"
  jobs="$(compute_jobs_with_mem_cap "${LLVM_CROSS_JOBS:-}" "${LLVM_CROSS_MB_PER_JOB:-3500}")"

  mkdir -p "${source_root}" "${build_root}"
  if [ ! -d "${source_dir}/.git" ]; then
    rm -rf "${source_dir}"
    log "Cloning llvm-project ${tag} for target LLVM ${target_label}"
    git clone --depth 1 --branch "${tag}" https://github.com/llvm/llvm-project.git "${source_dir}"
  fi

  rm -rf "${build_dir}"
  rm -rf "${wrapper_dir}"
  log "Building target LLVM ${release} for ${target_label} (${triplet})"
  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"

    setup_linux_cross_env

    mkdir -p "${wrapper_dir}"
    for tool in as ld ar nm ranlib strip objcopy; do
      case "${tool}" in
        as)      ln -sfn "${AS}"      "${wrapper_dir}/as" ;;
        ld)      ln -sfn "${LD}"      "${wrapper_dir}/ld" ;;
        ar)      ln -sfn "${AR}"      "${wrapper_dir}/ar" ;;
        nm)      ln -sfn "${NM}"      "${wrapper_dir}/nm" ;;
        ranlib)  ln -sfn "${RANLIB}"  "${wrapper_dir}/ranlib" ;;
        strip)   ln -sfn "${STRIP}"   "${wrapper_dir}/strip" ;;
        objcopy) ln -sfn "${OBJCOPY}" "${wrapper_dir}/objcopy" ;;
      esac
    done
    export PATH="${wrapper_dir}:${PATH}"

    cmake -G Ninja \
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
      -DCMAKE_C_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_CXX_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_ASM_FLAGS_INIT="-B${wrapper_dir}" \
      -DCMAKE_LIBRARY_ARCHITECTURE="${CROSS_TARGET_TRIPLET}" \
      -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
      -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
      -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
      -DCMAKE_INSTALL_PREFIX="${prefix}" \
      -DLLVM_HOST_TRIPLE="${triplet}" \
      -DLLVM_DEFAULT_TARGET_TRIPLE="${triplet}" \
      -DLLVM_TARGETS_TO_BUILD="${backend}" \
      -DLLVM_ENABLE_PROJECTS= \
      -DLLVM_ENABLE_RUNTIMES= \
      -DLLVM_BUILD_LLVM_DYLIB=ON \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLVM_INCLUDE_TOOLS=OFF \
      -DLLVM_BUILD_TOOLS=OFF \
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
    cmake --install "${build_dir}"
  )

  cmake_dir="$(llvm_cross_cmake_dir "${target_label}")" || die "Target LLVM CMake package missing after install for ${target_label}"
  log "Installed target LLVM package for ${target_label}: ${cmake_dir}"
}

build_cross_llvm_targets() {
  local targets_raw="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local target target_label

  [ "${BUILD_MODE:-native}" = "cross" ] || return 0

  for target in ${targets_raw//,/ }; do
    target_label="$(llvm_canonical_cross_target "${target}")" || {
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
    }

    [ "${target_label}" = "amd64" ] && continue
    install_cross_llvm_target_packages "${target_label}"
    build_cross_llvm_target "${target_label}"
  done
}

apt_has_package() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_install_available() {
  local pkgs=()
  local pkg
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

  if declare -F llvm_repo_available >/dev/null 2>&1 && ! llvm_repo_available "${DISTRO}"; then
    build_llvm_clang_from_source
    installed_from_source=1
  else
    case "$profile" in
      full)    install_llvm_clang_full ;;
      minimal) install_llvm_clang_minimal ;;
      *) die "Unknown LLVM_INSTALL_PROFILE: ${profile} (expected: full|minimal)" ;;
    esac

    # Register every versioned binary we find under /usr/bin that ends with -${CLANG_WANTED}
    # and set it as the chosen alternative.
    for full in /usr/bin/*-"${CLANG_WANTED}"; do
      # if glob didn't match, "$full" may be the literal pattern; skip non-existing entries
      [ -e "$full" ] || continue

      base="$(basename "$full")"
      tool="${base%-${CLANG_WANTED}}"

      # install the alternative and force it to the new path
      $SUDO update-alternatives --install "/usr/bin/${tool}" "${tool}" "$full" 100
      $SUDO update-alternatives --set "${tool}" "$full"
    done
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
  build_cross_llvm_targets
}
