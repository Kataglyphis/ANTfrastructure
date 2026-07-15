#!/usr/bin/env bash
set -euo pipefail

# smoke-toolchain.sh
# Validates the compiler toolchain inside the cross-compiler image:
#   - GCC 16.1.0 for all cross targets
#   - LLVM/Clang 22.1.8
#   - Rust/Cargo
#   - Python 3.14
#   - All cross-linkers produce correct ELF for each target
#
# Usage:
#   smoke-toolchain.sh                          # test all arches
#   smoke-toolchain.sh amd64,arm64              # test specific arches
#
# Designed to run inside Dockerfile.toolchain during the final bundle step.

# Prefer canonical versions.env over the fallback literals below (a stale
# PYTHON_VERSION default here once made smoke fail against a correctly built
# newer interpreter). Env values passed by the orchestrator still win.
for _sve in /opt/scripts/core/load-versions-env.sh \
            "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/load-versions-env.sh"; do
  if [ -f "${_sve}" ]; then
    # shellcheck disable=SC1090
    source "${_sve}"
    for _vef in /opt/scripts/core/versions.env \
                "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core/versions.env"; do
      [ -f "${_vef}" ] && { load_versions_env "${_vef}"; break; }
    done
    break
  fi
done
unset _sve _vef
: "${GCC_VERSION:=16.1.0}"
: "${LLVM_RELEASE:=22.1.8}"
: "${PYTHON_VERSION:=3.14.6}"
: "${PYTHON_MAJOR_MINOR:=3.14}"
: "${GCC_PREFIX:=/opt/gcc-${GCC_VERSION}}"

# Source shared smoke utilities
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_SCRIPT_DIR}/smoke-common.sh"

# Load platform helpers (from 01-core or /opt/scripts/core) if available
smoke_load_platform

smoke_target() {
  local target_arch="$1"
  local triplet

  triplet="$(smoke_deb_triplet "${target_arch}" 2>/dev/null || true)"
  [ -n "${triplet}" ] || { fail "Unknown arch: ${target_arch}"; return; }

  echo "--- Target: ${target_arch} (${triplet}) ---"

  local cross_gcc="${GCC_PREFIX}/bin/${triplet}-gcc"
  local cross_gpp="${GCC_PREFIX}/bin/${triplet}-g++"
  local cross_ld="${GCC_PREFIX}/bin/${triplet}-ld"

  validate_compiler_for_target "${cross_gcc}" "${target_arch}" "cross-gcc (${target_arch})" cross

  if [ -x "${cross_gpp}" ]; then
    local expected_pat
    expected_pat="$(smoke_uname_name "${target_arch}" 2>/dev/null || true)"
    check_dumpmachine "${cross_gpp}" "${expected_pat}" "cross-g++ (${target_arch})"
  fi
  if [ -x "${cross_ld}" ]; then
    pass "cross-ld exists for ${target_arch}"
  else
    fail "cross-ld (${triplet}-ld) not found"
  fi

  echo ""
}

print_smoke_header() {
  local host_arch="$1"
  local target_arches="$2"

  echo "=== Toolchain Smoke Test ==="
  echo "Host: ${host_arch}"
  echo "Targets: ${target_arches}"
  echo ""
}

check_host_gcc() {
  # Host GCC
  echo "--- Host GCC (amd64) ---"
  check_version "${GCC_PREFIX}/bin/gcc --version" "${GCC_VERSION}" "host gcc"
  check_dumpmachine "${GCC_PREFIX}/bin/gcc" "x86_64" "host gcc"
  check_version "${GCC_PREFIX}/bin/g++ --version" "${GCC_VERSION}" "host g++"
  echo ""
}

check_llvm_clang() {
  # LLVM/Clang
  echo "--- LLVM/Clang ---"
  check_version "clang --version" "${LLVM_RELEASE}" "clang"
  check_dumpmachine "$(command -v clang)" "x86_64" "host clang"
  check_version "clang++ --version" "${LLVM_RELEASE}" "clang++"
  echo ""
}

check_rust() {
  local target_arches="$1"

  # Rust
  echo "--- Rust/Cargo ---"
  check_version "rustc --version" "rustc" "rustc"
  check_version "cargo --version" "cargo" "cargo"
  for target in $(smoke_arch_words "${target_arches}"); do
    local rust_target
    rust_target="$(smoke_rust_target "${target}" 2>/dev/null || true)"
    # Guard: an unknown arch yields an empty rust_target, and `grep -q ""`
    # matches every line — which used to fake-pass the check.
    if [ -z "${rust_target}" ]; then
      fail "Rust target unknown for arch ${target} (no triple mapping)"
    elif rustup target list --installed 2>/dev/null | grep -q "${rust_target}"; then
      pass "Rust target ${rust_target} installed"
    else
      fail "Rust target ${rust_target} not installed"
    fi
  done
  echo ""
}

check_python() {
  local target_arches="$1"

  # Python
  echo "--- Python ---"
  check_version "/usr/local/bin/python${PYTHON_MAJOR_MINOR} --version" "${PYTHON_VERSION}" "python${PYTHON_MAJOR_MINOR}"
  local py_sysver
  py_sysver="$(/usr/local/bin/python${PYTHON_MAJOR_MINOR} -c "import sys; print(sys.version)" 2>/dev/null | head -1 || true)"
  if echo "${py_sysver}" | grep -q "${PYTHON_VERSION}"; then
    pass "python${PYTHON_MAJOR_MINOR} sys.version: ${py_sysver}"
  else
    fail "python${PYTHON_MAJOR_MINOR} sys.version: ${py_sysver:-MISSING} (expected ${PYTHON_VERSION})"
  fi
  for cross_arch in $(smoke_arch_words "${target_arches}"); do
    local py_root="/opt/python-cross/${cross_arch}"
    # A staged dir that is missing its .pc or binary is a broken staging —
    # fail explicitly instead of only pass-ing on the happy path.
    if [ -d "${py_root}" ]; then
      if [ -f "${py_root}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc" ]; then
        pass "Python ${PYTHON_MAJOR_MINOR} pkg-config exists for ${cross_arch}"
      else
        fail "Python ${PYTHON_MAJOR_MINOR} pkg-config missing for ${cross_arch} (expected ${py_root}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR}.pc)"
      fi
      if [ -f "${py_root}/usr/local/bin/python${PYTHON_MAJOR_MINOR}" ]; then
        pass "Python ${PYTHON_MAJOR_MINOR} binary staged for ${cross_arch}"
      else
        fail "Python ${PYTHON_MAJOR_MINOR} binary not staged for ${cross_arch} (expected ${py_root}/usr/local/bin/python${PYTHON_MAJOR_MINOR})"
      fi
    fi
  done
  echo ""
}

run_cross_targets() {
  local target_arches="$1"
  local host_arch="$2"

  # Cross-compilers for each target
  for arch in $(smoke_arch_words "${target_arches}"); do
    [ "${arch}" = "${host_arch}" ] && continue
    smoke_target "${arch}"
  done
}

main() {
  local target_arches="${1:-amd64,arm64,riscv64}"
  local host_arch

  host_arch="$(smoke_host_arch)"
  print_smoke_header "${host_arch}" "${target_arches}"
  check_host_gcc
  check_llvm_clang
  check_rust "${target_arches}"
  check_python "${target_arches}"
  run_cross_targets "${target_arches}" "${host_arch}"

  smoke_summary
}

main "$@"
