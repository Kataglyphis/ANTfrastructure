#!/usr/bin/env bash
# cross-env-doctor.sh — validate the cross-compilation environment contract.
#
# Usage (executable):
#   TARGET_ARCH=riscv64 linux/scripts/01-core/cross-env-doctor.sh
#   linux/scripts/01-core/cross-env-doctor.sh riscv64
# Usage (sourced):
#   source cross-env-doctor.sh && cross_env_doctor riscv64
#
# What it does:
#   1. Sources cross-env.sh and runs setup_linux_cross_env for TARGET_ARCH
#      (from arg 1 or the environment). BUILD_MODE defaults to "cross" here —
#      the doctor exists to diagnose the cross path.
#   2. Validates the Tier-1 contract vars are set and CC/CXX are executable.
#   3. Prints the effective config table, including the Tier-2 rust/cmake
#      derivations.
#   4. Compiles a tiny C program with $CC and asserts the output ELF machine
#      matches the target architecture.
#   5. Exits nonzero with a consolidated failure list.

_CROSS_DOCTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_CROSS_DOCTOR_DIR}/cross-env.sh"

_doctor_kv() {
  printf '  %-38s = %s\n' "$1" "${2:-<unset>}"
}

# Print a dynamically named variable (e.g. CARGO_TARGET_..._LINKER).
_doctor_kv_indirect() {
  local name="$1"
  _doctor_kv "${name}" "${!name-}"
}

# Step 1: target selection + env setup. Appends a failure description to the
# nameref'd array if the requested arch is invalid, cross is inactive, or
# setup_linux_cross_env fails.
_doctor_phase_target_setup() {
  local -n _dpts_failures="$1"
  local target_arch="$2"

  if ! cross_set_target_env "${target_arch}" "cross-env doctor"; then
    _dpts_failures+=("TARGET_ARCH invalid or unset (got '${target_arch:-}'); pass an arch arg or export TARGET_ARCH")
  elif ! cross_build_enabled; then
    _dpts_failures+=("cross build not active: BUILD_MODE=${BUILD_MODE} and/or TARGET_ARCH=${TARGET_ARCH} equals build arch $(cross_build_arch) — nothing to cross-compile")
  elif ! setup_linux_cross_env; then
    _dpts_failures+=("setup_linux_cross_env failed for TARGET_ARCH=${TARGET_ARCH} — cross toolchain for $(cross_target_triplet 2>/dev/null || echo '?') not installed?")
  fi
}

# Step 2: Tier-1 contract vars. Verifies required vars are set and that CC/CXX
# point to executable binaries. Appends one failure per missing/broken var.
_doctor_phase_tier1_contract() {
  local -n _dpt1_failures="$1"
  local var

  for var in TARGET_ARCH CROSS_TARGET_TRIPLET CC CXX AR RANLIB STRIP \
    PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR; do
    if [ -z "${!var-}" ]; then
      _dpt1_failures+=("Tier-1 contract var ${var} is not set")
    fi
  done
  for var in CC CXX; do
    if [ -n "${!var-}" ] && ! command -v "${!var}" >/dev/null 2>&1; then
      _dpt1_failures+=("${var}=${!var} does not exist or is not executable")
    fi
  done
}

# Step 3: effective config table (Tier 1, rust derivations, cmake derivations).
# Pure printing; no failures.
_doctor_phase_config_table() {
  local rust_env_upper rust_env_lower bare_dir

  rust_env_upper="$(cross_target_upper_rust 2>/dev/null || true)"
  rust_env_lower="$(cross_target_lower_rust 2>/dev/null || true)"

  printf '\n-- Tier 1: core toolchain contract --\n'
  local var
  for var in TARGET_ARCH TARGETARCH TARGETPLATFORM BUILDARCH CROSS_TARGET_TRIPLET \
    CC CXX AR AS LD NM RANLIB STRIP OBJCOPY \
    PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_ALLOW_CROSS; do
    _doctor_kv_indirect "${var}"
  done
  _doctor_kv "cross_bin_dir (PATH, prefixed only)" "$(cross_bin_dir 2>/dev/null || true)"
  bare_dir="$(cross_bare_bin_path 2>/dev/null || true)"
  _doctor_kv "cross_bare_bin_path (opt-in, off PATH)" "${bare_dir:-<absent>}"

  printf '\n-- Tier 2: rust derivations --\n'
  for var in CROSS_RUST_TARGET CARGO_BUILD_TARGET CARGO_TARGET_DIR; do
    _doctor_kv_indirect "${var}"
  done
  if [ -n "${rust_env_upper}" ]; then
    _doctor_kv_indirect "CARGO_TARGET_${rust_env_upper}_LINKER"
    _doctor_kv_indirect "CARGO_TARGET_${rust_env_upper}_AR"
  fi
  if [ -n "${rust_env_lower}" ]; then
    for var in "CC_${rust_env_lower}" "CXX_${rust_env_lower}" "AR_${rust_env_lower}" "RANLIB_${rust_env_lower}"; do
      _doctor_kv_indirect "${var}"
    done
  fi

  printf '\n-- Tier 2: cmake derivations --\n'
  for var in CMAKE_SYSTEM_NAME CMAKE_SYSTEM_PROCESSOR CMAKE_SYSROOT \
    CMAKE_C_COMPILER CMAKE_CXX_COMPILER CMAKE_AR CMAKE_RANLIB CMAKE_LINKER \
    CMAKE_LIBRARY_ARCHITECTURE CMAKE_FIND_ROOT_PATH_MODE_PROGRAM; do
    _doctor_kv_indirect "${var}"
  done
}

# Step 4: compile a hello-world C program with $CC and assert the output ELF
# machine field matches the target architecture. Appends a failure description
# on any error (CC unset, compile failure, readelf missing, machine mismatch).
_doctor_phase_compile_smoke() {
  local -n _dpcs_failures="$1"

  if [ -n "${CC:-}" ] && command -v "${CC}" >/dev/null 2>&1; then
    local work src bin expected machine
    work="$(mktemp -d "${TMPDIR:-/tmp}/cross-doctor.XXXXXX")"
    src="${work}/hello.c"
    bin="${work}/hello"
    printf '#include <stdio.h>\nint main(void) { printf("hello cross\\n"); return 0; }\n' > "${src}"
    if ! "${CC}" -o "${bin}" "${src}" 2> "${work}/cc.err"; then
      _dpcs_failures+=("compile smoke failed: ${CC} could not build a hello world ($(head -c 300 "${work}/cc.err" | tr '\n' ' '))")
    else
      expected="$(arch_elf_machine_grep_for "${TARGET_ARCH:-}" 2>/dev/null || true)"
      machine="$(elf_machine_name "${bin}" 2>/dev/null || true)"
      if [ -z "${expected}" ]; then
        _dpcs_failures+=("no ELF machine pattern known for TARGET_ARCH=${TARGET_ARCH:-<unset>}")
      elif [ -z "${machine}" ]; then
        _dpcs_failures+=("could not read ELF machine of compiled binary (readelf missing?)")
      else
        case "${machine}" in
          *"${expected}"*)
            printf '\ncompile smoke OK: %s -> ELF Machine "%s" matches %s\n' "${CC}" "${machine}" "${TARGET_ARCH}"
            ;;
          *)
            _dpcs_failures+=("ELF machine mismatch: ${CC} produced Machine '${machine}', expected pattern '${expected}' for ${TARGET_ARCH}")
            ;;
        esac
      fi
    fi
    rm -rf "${work}"
  else
    _dpcs_failures+=("compile smoke skipped: CC is unset or not executable")
  fi
}

# Step 5: print a consolidated verdict. Returns 1 on failures, 0 on success.
_doctor_phase_verdict() {
  local -n _dpv_failures="$1"
  if [ "${#_dpv_failures[@]}" -gt 0 ]; then
    printf '\nFAIL: %d problem(s) found:\n' "${#_dpv_failures[@]}" >&2
    local f
    for f in "${_dpv_failures[@]}"; do
      printf '  - %s\n' "${f}" >&2
    done
    return 1
  fi

  printf '\nOK: cross environment contract satisfied for TARGET_ARCH=%s\n' "${TARGET_ARCH}"
  return 0
}

cross_env_doctor() {
  local target_arch="${1:-${TARGET_ARCH:-${TARGETARCH:-${ARCH:-}}}}"
  local -a failures=()

  export BUILD_MODE="${BUILD_MODE:-cross}"

  printf '== cross-env doctor ==\n'
  printf 'requested TARGET_ARCH=%s BUILD_MODE=%s build_arch=%s\n' \
    "${target_arch:-<unset>}" "${BUILD_MODE}" "$(cross_build_arch 2>/dev/null || echo '<unknown>')"

  _doctor_phase_target_setup   failures "${target_arch}"
  _doctor_phase_tier1_contract failures
  _doctor_phase_config_table
  _doctor_phase_compile_smoke  failures
  _doctor_phase_verdict        failures
}

# Executed directly (not sourced): run the doctor.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  cross_env_doctor "$@"
  exit $?
fi
