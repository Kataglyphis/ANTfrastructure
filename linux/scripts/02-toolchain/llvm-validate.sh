#!/usr/bin/env bash
# llvm-validate.sh — LLVM cross-compiled package validation functions.
# Sourced by llvm.sh; not executed standalone.
[ -n "${_LLVM_VALIDATE_SH_LOADED:-}" ] && return 0
_LLVM_VALIDATE_SH_LOADED=1
set -euo pipefail

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
    die "Target LLVM compatibility shared umbrella lib missing for ${target_label}: ${prefix}/lib/libLLVM-$(llvm_wanted_major).so"
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
  major="$(llvm_wanted_major)"
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

  local _script_dir
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local _apply_patch="${_script_dir}/01-core/apply-patch.sh"
  local _patch_file="${_script_dir}/patches/llvm/001-component-libs-property.patch"

  bash "${_apply_patch}" "${_patch_file}" "${source_dir}" \
    "LLVMConfig.cmake.in: set LLVM_COMPONENT_LIBS global property"
}
