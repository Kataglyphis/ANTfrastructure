#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain

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

llvm_selected_host_clang() {
  local candidate=""

  for candidate in \
    "clang-${CLANG_WANTED}" \
    clang; do
    command -v "${candidate}" >/dev/null 2>&1 || continue
    command -v "${candidate}"
    return 0
  done

  return 1
}

llvm_selected_host_clangxx() {
  local candidate=""

  for candidate in \
    "clang++-${CLANG_WANTED}" \
    clang++; do
    command -v "${candidate}" >/dev/null 2>&1 || continue
    command -v "${candidate}"
    return 0
  done

  return 1
}

register_versioned_llvm_binaries() {
  local full base tool

  # Register every versioned binary we find under /usr/bin that ends with -${CLANG_WANTED}
  # and set it as the chosen alternative.
  for full in /usr/bin/*-"${CLANG_WANTED}"; do
    [ -e "$full" ] || continue

    base="$(basename "$full")"
    tool="${base%-${CLANG_WANTED}}"

    $SUDO update-alternatives --install "/usr/bin/${tool}" "${tool}" "$full" 100
    $SUDO update-alternatives --set "${tool}" "$full"
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

    wrapper="/usr/local/bin/clang-${target_label}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec "${host_clang}" --target=${triplet} --sysroot=${sysroot} --gcc-toolchain=${gcc_prefix} "\$@"
EOF
    chmod +x "${wrapper}"
    log "Installed LLVM wrapper: $(basename "${wrapper}")"

    wrapper="/usr/local/bin/clang++-${target_label}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec "${host_clangxx}" --target=${triplet} --sysroot=${sysroot} --gcc-toolchain=${gcc_prefix} "\$@"
EOF
    chmod +x "${wrapper}"
    log "Installed LLVM wrapper: $(basename "${wrapper}")"
  done
}

llvm_cross_backend() {
  case "$(arch_normalize "$1")" in
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
    22) printf '%s' "22.1.6" ;;
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
  local major="${LLVM_WANTED:-${CLANG_WANTED:-22}}"
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
  local major="${LLVM_WANTED:-${CLANG_WANTED:-22}}"
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
}

llvm_cmake_package_has_component_metadata() {
  local llvm_config_file="$1"

  grep -q 'set_property(GLOBAL PROPERTY LLVM_COMPONENT_LIBS "${LLVM_AVAILABLE_LIBS}")' "${llvm_config_file}" && return 0
  grep -q '^set(LLVM_AVAILABLE_LIBS[[:space:]]' "${llvm_config_file}" && return 0
  return 1
}

validate_cross_llvm_cmake_package() {
  local target_label="$1"
  local prefix cmake_dir llvm_config_file exports_file

  prefix="$(llvm_cross_install_prefix "${target_label}")" || return 1
  cmake_dir="$(llvm_cross_cmake_dir "${target_label}" 2>/dev/null || true)"
  [ -n "${cmake_dir}" ] || die "Target LLVM CMake package missing for ${target_label}"

  llvm_config_file="${cmake_dir}/LLVMConfig.cmake"
  exports_file="${cmake_dir}/LLVMExports.cmake"
  [ -f "${llvm_config_file}" ] || die "Target LLVMConfig.cmake missing for ${target_label}: ${llvm_config_file}"

  llvm_cross_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || \
    die "Target LLVM shared umbrella lib missing for ${target_label}: ${prefix}/lib/libLLVM.so"
  llvm_cross_versioned_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || \
    die "Target LLVM versioned shared umbrella lib missing for ${target_label} under ${prefix}"
  llvm_cross_compat_shared_umbrella_lib_path "${prefix}" >/dev/null 2>&1 || \
    die "Target LLVM compatibility shared umbrella lib missing for ${target_label}: ${prefix}/lib/libLLVM-${LLVM_WANTED:-${CLANG_WANTED:-22}}.so"
  llvm_cross_llvm_config_path "${prefix}" >/dev/null 2>&1 || \
    die "Target llvm-config missing for ${target_label} under ${prefix}/bin"

  grep -Eq '^set\(LLVM_LINK_LLVM_DYLIB (ON|TRUE|YES|1)\)$' "${llvm_config_file}" || \
    die "Target LLVM package for ${target_label} does not advertise LLVM_LINK_LLVM_DYLIB=ON"
  grep -Eq '^set\(LLVM_DYLIB_COMPONENTS [^)]*[[:alnum:]_]' "${llvm_config_file}" || \
    die "Target LLVM package for ${target_label} does not advertise LLVM_DYLIB_COMPONENTS"

  if [ -f "${exports_file}" ] && grep -q 'INTERFACE_LINK_LIBRARIES "LLVM' "${exports_file}"; then
    grep -q 'add_library(LLVM ' "${exports_file}" || \
      die "Target LLVM exports for ${target_label} reference LLVM without defining an imported LLVM target"
  fi

  llvm_cmake_package_has_component_metadata "${llvm_config_file}" || \
    die "Target LLVM package for ${target_label} does not provide LLVM component metadata"
}

install_cross_llvm_runner_tools() {
  cross_mode_requested || return 0

  if command -v qemu-aarch64 >/dev/null 2>&1 && command -v qemu-riscv64 >/dev/null 2>&1; then
    return 0
  fi

  if apt_has_package qemu-user; then
    apt_install qemu-user
    return 0
  fi

  if apt_has_package qemu-user-static; then
    apt_install qemu-user-static
    return 0
  fi

  die "Neither qemu-user nor qemu-user-static is available for target llvm-config verification"
}

install_cross_llvm_config_binary() {
  local target_label="$1"
  local build_dir="$2"
  local llvm_config_src bin_dir major

  llvm_config_src="${build_dir}/bin/llvm-config"
  [ -x "${llvm_config_src}" ] || die "Cross llvm-config build output missing for ${target_label}: ${llvm_config_src}"

  bin_dir="$(llvm_cross_bin_dir "${target_label}")" || die "Unable to resolve LLVM bin dir for ${target_label}"
  major="${LLVM_WANTED:-${CLANG_WANTED:-22}}"
  major="$(version_major "${major}")"

  mkdir -p "${bin_dir}"
  install -m755 "${llvm_config_src}" "${bin_dir}/llvm-config"
  ln -sfn llvm-config "${bin_dir}/llvm-config-${major}"
}

verify_cross_llvm_config() {
  local target_label="$1"
  local prefix expected_libdir llvm_config_path actual_libdir shared_mode

  prefix="$(llvm_cross_install_prefix "${target_label}")" || return 1
  expected_libdir="$(llvm_cross_lib_dir "${prefix}")" || \
    die "Target LLVM libdir missing for ${target_label}: ${prefix}"
  llvm_config_path="$(llvm_cross_llvm_config_path "${prefix}")" || \
    die "Target llvm-config missing for ${target_label}: ${prefix}/bin/llvm-config"

  actual_libdir="$(llvm_cross_run_binary "${target_label}" "${llvm_config_path}" --libdir)"
  [ "${actual_libdir}" = "${expected_libdir}" ] || \
    die "Target llvm-config for ${target_label} reports libdir ${actual_libdir}, expected ${expected_libdir}"

  shared_mode="$(llvm_cross_run_binary "${target_label}" "${llvm_config_path}" --shared-mode all)"
  [ "${shared_mode}" = "shared" ] || \
    die "Target llvm-config for ${target_label} reports --shared-mode ${shared_mode:-<empty>} (expected shared)"
}

verify_cross_llvm_cmake_smoke_test() {
  local target_label="$1"
  local cmake_dir smoke_root wrapper_dir
  local -a cmake_args=(
    -G Ninja
  )

  cmake_dir="$(llvm_cross_cmake_dir "${target_label}")" || \
    die "Target LLVM CMake package missing for ${target_label}"
  smoke_root="$(mktemp -d "/tmp/llvm-cross-${target_label}.XXXXXX")"
  wrapper_dir="${smoke_root}/tool-bin"

  cat > "${smoke_root}/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(llvm_cross_smoke LANGUAGES CXX)
find_package(LLVM REQUIRED CONFIG)
if (NOT TARGET LLVM)
  message(FATAL_ERROR "LLVM imported target missing")
endif()
add_executable(llvm_cross_smoke main.cpp)
target_link_libraries(llvm_cross_smoke PRIVATE LLVM)
EOF
  cat > "${smoke_root}/main.cpp" <<'EOF'
int main() { return 0; }
EOF

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    export TARGETPLATFORM="linux/${target_label}"

    setup_linux_cross_env
    llvm_cross_populate_tool_wrapper_dir "${wrapper_dir}"
    export PATH="${wrapper_dir}:${PATH}"
    append_cmake_cross_args cmake_args
    cmake_args+=( "-DLLVM_DIR=${cmake_dir}" )
    cmake_args+=(
      "-DCMAKE_C_FLAGS_INIT=-B${wrapper_dir}"
      "-DCMAKE_CXX_FLAGS_INIT=-B${wrapper_dir}"
      "-DCMAKE_ASM_FLAGS_INIT=-B${wrapper_dir}"
    )

    cmake -S "${smoke_root}" -B "${smoke_root}/build" "${cmake_args[@]}"
    cmake --build "${smoke_root}/build" --parallel 1
  )

  rm -rf "${smoke_root}"
}

verify_cross_llvm_target() {
  local target_label="$1"
  local prefix

  prefix="$(llvm_cross_install_prefix "${target_label}")" || return 1
  log "Verifying target LLVM package for ${target_label}: ${prefix}"
  validate_cross_llvm_cmake_package "${target_label}"
  verify_cross_llvm_config "${target_label}"
  verify_cross_llvm_cmake_smoke_test "${target_label}"
}

verify_cross_llvm_targets() {
  local targets_raw=""
  local target target_label

  cross_mode_requested || return 0

  if declare -F cross_effective_targets_raw >/dev/null 2>&1; then
    targets_raw="$(cross_effective_targets_raw)"
  else
    targets_raw="${VERIFY_CROSS_TARGETS:-${CROSS_TARGETS:-amd64,arm64,riscv64}}"
  fi
  [ -n "${targets_raw}" ] || return 0
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || {
    log "Skipping unsupported LLVM cross verification target list: ${targets_raw}"
    return 0
  }

  for target in ${targets_raw//,/ }; do
    target_label="$(arch_normalize "${target}")"
    case "${target_label}" in
      amd64|arm64|riscv64) ;;
      *)
      log "Skipping unsupported LLVM cross verification target: ${target}"
      continue
      ;;
    esac

    [ "${target_label}" = "amd64" ] && continue
    verify_cross_llvm_target "${target_label}"
  done
}

patch_cross_llvm_config_template() {
  local source_dir="$1"
  local template_file="${source_dir}/llvm/cmake/modules/LLVMConfig.cmake.in"

  [ -f "${template_file}" ] || die "LLVMConfig.cmake.in not found: ${template_file}"

  python3 - "${template_file}" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
text = template_path.read_text()
line = 'set_property(GLOBAL PROPERTY LLVM_COMPONENT_LIBS "${LLVM_AVAILABLE_LIBS}")'
marker = 'include(${LLVM_CMAKE_DIR}/LLVM-Config.cmake)'

if line in text:
    raise SystemExit(0)
if marker not in text:
    raise SystemExit(f"expected marker not found in {template_path}")

template_path.write_text(text.replace(marker, marker + '\n' + line, 1))
PY

  grep -q 'set_property(GLOBAL PROPERTY LLVM_COMPONENT_LIBS "${LLVM_AVAILABLE_LIBS}")' "${template_file}" || \
    die "Failed to patch LLVMConfig.cmake.in for installed package component metadata"
}

llvm_host_native_tool_dir() {
  local major="${LLVM_WANTED:-${CLANG_WANTED:-22}}"
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

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || die "Unsupported LLVM cross target: ${target_label}"
  backend="$(llvm_cross_backend "${target_label}")" || die "Unsupported LLVM backend target: ${target_label}"
  prefix="$(llvm_cross_install_prefix "${target_label}")" || die "Unable to resolve LLVM cross install prefix for ${target_label}"
  if cmake_dir="$(llvm_cross_cmake_dir "${target_label}" 2>/dev/null || true)"; then
    if [ -n "${cmake_dir}" ]; then
      if llvm_cross_install_looks_complete "${target_label}"; then
        validate_cross_llvm_cmake_package "${target_label}"
        log "Reusing target LLVM install for ${target_label}: ${cmake_dir}"
        return 0
      fi

      log "Discarding incomplete target LLVM install for ${target_label}: ${prefix}"
      rm -rf "${prefix}"
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
  patch_cross_llvm_config_template "${source_dir}"

  rm -rf "${prefix}"
  rm -rf "${build_dir}"
  rm -rf "${wrapper_dir}"
  log "Building target LLVM ${release} for ${target_label} (${triplet})"
  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    export CCACHE_DIR="/var/cache/ccache"
    export SCCACHE_DIR="/var/cache/sccache"

    setup_linux_cross_env

    llvm_cross_populate_tool_wrapper_dir "${wrapper_dir}"
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
    cmake --build "${build_dir}" --parallel "${jobs}" --target llvm-config
    cmake --install "${build_dir}"
  )

  install_cross_llvm_config_binary "${target_label}" "${build_dir}"

  cmake_dir="$(llvm_cross_cmake_dir "${target_label}")" || die "Target LLVM CMake package missing after install for ${target_label}"
  validate_cross_llvm_cmake_package "${target_label}"
  log "Installed target LLVM package for ${target_label}: ${cmake_dir}"
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

# ---------------------------------------------------------------------------
# Cross-compile a full Clang/LDD/compiler-rt toolchain for a foreign target
# architecture.  Called from Dockerfile.sdk so each architecture (arm64,
# riscv64) ships its own native clang 22.1.6 in the final :latest-cross image.
# ---------------------------------------------------------------------------
install_target_clang_toolchain() {
  local target_label="${1:-${TARGET_ARCH:-${TARGETARCH:-}}}"
  local triplet backend prefix source_root build_root source_dir build_dir
  local wrapper_dir native_wrapper_dir jobs release tag native_tool_dir build_cc build_cxx
  local build_cc_real build_cxx_real host_path target_runtime_link_path linker_flags_init link_dir
  local llvm_major="${LLVM_WANTED:-$(version_major "${LLVM_RELEASE:-${CLANG_WANTED:-22}}")}"

  [ -n "${target_label}" ] || die "install_target_clang_toolchain: target architecture required"
  target_label="$(arch_normalize "${target_label}")"
  [ "${target_label}" = "amd64" ] && { log "Skipping target-clang for amd64 (host clang already serves)"; return 0; }

  triplet="$(arch_deb_multiarch_triplet_for "${target_label}")" || die "No triplet for ${target_label}"
  local clang_triple="${triplet}"
  if [ "${target_label}" = "arm64" ]; then
    clang_triple="aarch64-unknown-linux-gnu"
  elif [ "${target_label}" = "riscv64" ]; then
    clang_triple="riscv64-unknown-linux-gnu"
  fi
  backend="$(llvm_cross_backend "${target_label}")" || die "No LLVM backend for ${target_label}"
  prefix="/opt/llvm-target"
  release="${LLVM_RELEASE:-22.1.6}"
  tag="llvmorg-${release}"
  source_root="${LLVM_CROSS_SOURCE_ROOT:-/var/tmp/llvm-cross-src}"
  build_root="${LLVM_CROSS_BUILD_ROOT:-/var/tmp/llvm-cross-build}"
  source_dir="${source_root}/llvm-project-${release}"
  build_dir="${build_root}/target-clang-${target_label}"
  wrapper_dir="${build_root}/target-clang-${target_label}-tool-bin"
  jobs="$(compute_jobs_with_mem_cap "${LLVM_CROSS_JOBS:-}" "${LLVM_CROSS_MB_PER_JOB:-3500}")"

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

  mkdir -p "${source_root}" "${build_root}"
  if [ ! -d "${source_dir}/.git" ]; then
    rm -rf "${source_dir}"
    log "Cloning llvm-project ${tag} for target clang ${target_label}"
    git clone --depth 1 --branch "${tag}" https://github.com/llvm/llvm-project.git "${source_dir}"
  fi

  native_tool_dir="$(llvm_host_native_tool_dir)" || die "Host LLVM native tools not found"
  build_cc_real="$(resolve_build_gcc_tool gcc 2>/dev/null || command -v gcc 2>/dev/null || true)"
  build_cxx_real="$(resolve_build_gcc_tool g++ 2>/dev/null || command -v g++ 2>/dev/null || true)"
  [ -n "${build_cc_real}" ] || die "Host C compiler not found for LLVM native helper tools"
  [ -n "${build_cxx_real}" ] || die "Host C++ compiler not found for LLVM native helper tools"
  host_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  native_wrapper_dir="${build_root}/target-clang-${target_label}-native-tool-bin"

  rm -rf "${prefix}" "${build_dir}" "${wrapper_dir}" "${native_wrapper_dir}"
  log "Building target clang ${release} for ${target_label} (${triplet}) — this will take a while"

  (
    export BUILD_MODE=cross
    export TARGETARCH="${target_label}"
    export TARGET_ARCH="${target_label}"
    export CCACHE_DIR="/var/cache/ccache"
    export SCCACHE_DIR="/var/cache/sccache"
    setup_linux_cross_env
    llvm_cross_populate_tool_wrapper_dir "${wrapper_dir}"
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
      "-DCMAKE_EXE_LINKER_FLAGS_INIT=${linker_flags_init}" \
      "-DCMAKE_SHARED_LINKER_FLAGS_INIT=${linker_flags_init}" \
      "-DCMAKE_MODULE_LINKER_FLAGS_INIT=${linker_flags_init}" \
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
      -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
      -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
      -DCOMPILER_RT_BUILD_SANITIZERS=ON \
      -DCOMPILER_RT_BUILD_BUILTINS=ON \
      -DCOMPILER_RT_BUILD_XRAY=OFF \
      -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
      -DCOMPILER_RT_BUILD_PROFILE=ON \
      -DCOMPILER_RT_BUILD_MEMPROF=OFF \
      -DCOMPILER_RT_BUILD_ORC=OFF \
      -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
      -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
      -DSANITIZER_CXX_ABI=libstdc++ \
      -DLLVM_BUILD_LLVM_DYLIB=ON \
      -DLLVM_LINK_LLVM_DYLIB=ON \
      -DLLVM_USE_HOST_TOOLS=ON \
      "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=${build_cc};-DCMAKE_CXX_COMPILER=${build_cxx};-DCMAKE_ASM_COMPILER=${build_cc}" \
      -DLLVM_INCLUDE_TOOLS=ON \
      -DLLVM_BUILD_TOOLS=ON \
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
      -DLLVM_TABLEGEN="${native_tool_dir}/llvm-tblgen" \
      -DCLANG_TABLEGEN="${native_tool_dir}/clang-tblgen"

    cmake --build "${build_dir}" --parallel "${jobs}"
    cmake --install "${build_dir}"
  )

  if [ -x "${prefix}/bin/clang" ]; then
    log "Target clang ${release} for ${target_label} installed at ${prefix}"
  else
    die "Target clang build for ${target_label} completed but ${prefix}/bin/clang not found"
  fi
}
