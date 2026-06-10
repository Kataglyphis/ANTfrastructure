#!/usr/bin/env bash
set -euo pipefail

# validate-compilers.sh
# Unified compiler chain validation for GCC 16.1.0 and Clang 22.1.6.
# Called from Dockerfile.package (artifact-source, package, and wrapper-smoke targets).
#
# Modes:
#   artifact-source   Validate compilers inside the artifact carrier image
#                     (host GCC, cross GCC, target-native GCC, target Clang).
#   package           Wire alternatives for GCC/LLVM and hard-fail if
#                     cc -dumpmachine does not match TARGET_ARCH.
#   smoke             Runtime smoke: GCC version, Clang version,
#                     cc -dumpmachine, symlink chains, optional payloads.
#
# Usage:
#   validate-compilers.sh artifact-source
#   validate-compilers.sh package
#   validate-compilers.sh smoke

_vcs_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_vcs_script_dir}/../01-core/modules.sh"
source_module platform.sh

validate_resolve_arch() {
  canonical_target_arch "${1:-${TARGET_ARCH:-}}"
}

validate_fail() {
  echo "COMPILER FAIL [$1]: $2" >&2
  _VALIDATE_ERRORS=$((_VALIDATE_ERRORS + 1))
}

validate_artifact_source() {
  local target_arch gcc_prefix errors llvm_target
  target_arch="$(validate_resolve_arch)"
  echo "=== artifact-source: verifying compilers for target_arch=${target_arch} ==="
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  _VALIDATE_ERRORS=0

  # host GCC
  if [ -x "${gcc_prefix}/bin/gcc" ]; then
    local host_ver
    host_ver="$("${gcc_prefix}/bin/gcc" --version 2>/dev/null | head -1 || true)"
    if echo "${host_ver}" | grep -q "${GCC_VERSION:-16.1.0}"; then
      echo "OK: host gcc ${gcc_prefix}/bin/gcc reports ${host_ver}"
    else
      validate_fail "host-gcc" "${gcc_prefix}/bin/gcc --version: ${host_ver:-MISSING} (expected ${GCC_VERSION:-16.1.0})"
    fi
  else
    validate_fail "host-gcc-missing" "${gcc_prefix}/bin/gcc not found"
  fi

  # cross compilers — derive list from CROSS_TARGETS or platform default
  local cross_arches="${CROSS_TARGETS:-amd64,arm64,riscv64}"
  local cross_arch triplet cross_gcc cross_ver
  for cross_arch in ${cross_arches//,/ }; do
    [ "${cross_arch}" = "${target_arch}" ] && continue
    triplet="$(arch_deb_multiarch_triplet_for "${cross_arch}" 2>/dev/null || true)"
    [ -n "${triplet}" ] || continue
    cross_gcc="${gcc_prefix}/bin/${triplet}-gcc"
    if [ -x "${cross_gcc}" ]; then
      cross_ver="$("${cross_gcc}" --version 2>/dev/null | head -1 || true)"
      if echo "${cross_ver}" | grep -q "${GCC_VERSION:-16.1.0}"; then
        echo "OK: cross ${cross_gcc} reports ${cross_ver}"
      else
        validate_fail "cross-gcc-${cross_arch}" "${cross_gcc} --version: ${cross_ver:-MISSING}"
      fi
    fi
  done

  # target-native GCC
  if [ "${target_arch}" != "amd64" ]; then
    local native_gcc="/opt/gcc-${GCC_VERSION:-16.1.0}-native-${target_arch}"
    if [ -d "${native_gcc}" ] && [ -x "${native_gcc}/bin/gcc" ]; then
      local native_ver
      native_ver="$("${native_gcc}/bin/gcc" --version 2>/dev/null | head -1 || true)"
      if echo "${native_ver}" | grep -q "${GCC_VERSION:-16.1.0}"; then
        echo "OK: target-native ${native_gcc}/bin/gcc reports ${native_ver}"
      else
        validate_fail "native-gcc" "${native_gcc}/bin/gcc --version: ${native_ver:-MISSING}"
      fi
    elif [ "${BUILD_MODE:-native}" = "cross" ]; then
      # The GCC swap in Dockerfile.android may have already moved the
      # native GCC into /opt/gcc-${GCC_VERSION}.  If the main GCC
      # already reports the correct architecture, the swap succeeded.
      local main_gcc_dump
      main_gcc_dump="$("${gcc_prefix}/bin/gcc" -dumpmachine 2>/dev/null || true)"
      case "${target_arch}" in
        arm64)   expected_triple="aarch64-linux-gnu" ;;
        riscv64) expected_triple="riscv64-linux-gnu" ;;
        *)       expected_triple="" ;;
      esac
      if [ -n "${expected_triple}" ] && [ "${main_gcc_dump}" = "${expected_triple}" ]; then
        echo "OK: main gcc already reports target-native triple ${main_gcc_dump} (swap completed)"
      else
        validate_fail "native-gcc-missing" "expected target-native GCC at ${native_gcc}/bin/gcc for ${target_arch}"
      fi
    fi
  fi

  # target-native Clang
  llvm_target="/opt/llvm-target/bin/clang"
  if [ ! -e /opt/llvm-target ]; then
    validate_fail "llvm-target-missing" "/opt/llvm-target symlink/directory not found (should be created by setup step)"
  fi
  if [ -x "${llvm_target}" ]; then
    local clang_ver clang_major_minor
    clang_ver="$("${llvm_target}" --version 2>/dev/null | head -1 || true)"
    if echo "${clang_ver}" | grep -q "${LLVM_RELEASE:-22.1.6}"; then
      echo "OK: target clang ${llvm_target} reports ${clang_ver}"
    else
      # Check major.minor match (artifact may have minor patch drift)
      clang_major_minor="${LLVM_RELEASE%.*}"
      if [[ "${clang_ver}" == *"clang version ${clang_major_minor}"* ]]; then
        echo "OK: target clang ${llvm_target} reports ${clang_ver} (major.minor ${clang_major_minor} matches)"
      else
        validate_fail "target-clang" "${llvm_target} --version: ${clang_ver:-MISSING} (expected ${LLVM_RELEASE:-22.1.6})"
      fi
    fi
  elif [ "${BUILD_MODE:-native}" = "cross" ] && [ -d /opt/llvm-target ]; then
    validate_fail "target-clang-missing" "${llvm_target} not executable in /opt/llvm-target"
  else
    echo "WARNING: missing target-native LLVM toolchain for ${target_arch}; continuing with distro LLVM"
  fi

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "ARTIFACT COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
  echo "ARTIFACT COMPILER VERIFICATION PASSED for ${target_arch}"
}

validate_package() {
  local target_arch gcc_prefix
  target_arch="$(validate_resolve_arch)"
  _VALIDATE_ERRORS=0

  # --- wire target-native LLVM alternatives ---
  if [ -d /usr/local/llvm-target ]; then
    require_target_llvm_tool() {
      local name="$1" priority="${2:-120}"
      local candidate="/usr/local/llvm-target/bin/${name}"
      [ -x "${candidate}" ] || {
        echo "WARNING: expected target-native LLVM tool missing: ${candidate}" >&2
        return 0
      }
      update-alternatives --install "/usr/bin/${name}" "${name}" "${candidate}" "${priority}"
      update-alternatives --set "${name}" "${candidate}"
    }
    require_target_llvm_tool clang
    require_target_llvm_tool clang++
    require_target_llvm_tool llvm-ar
    require_target_llvm_tool llvm-ranlib
  else
    echo "WARNING: /usr/local/llvm-target not found; using distro LLVM"
  fi

  # --- wire GCC alternatives ---
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.1.0}"
  if [ -d "${gcc_prefix}" ]; then
    local tool candidate
    for tool in gcc g++ gcov; do
      candidate="${gcc_prefix}/bin/${tool}"
      if [ -x "${candidate}" ]; then
        update-alternatives --install "/usr/bin/${tool}" "${tool}" "${candidate}" 150
        update-alternatives --set "${tool}" "${candidate}"
      fi
    done
    if [ -x "${gcc_prefix}/bin/gcc" ]; then
      update-alternatives --install /usr/bin/cc cc "${gcc_prefix}/bin/gcc" 150
      update-alternatives --set cc "${gcc_prefix}/bin/gcc"
    fi
    if [ -x "${gcc_prefix}/bin/g++" ]; then
      update-alternatives --install /usr/bin/c++ c++ "${gcc_prefix}/bin/g++" 150
      update-alternatives --set c++ "${gcc_prefix}/bin/g++"
    fi
  else
    echo "WARNING: Custom GCC prefix ${gcc_prefix} not found"
  fi

  _validate_cc_target "${target_arch}" hard-fail

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "PACKAGE COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
}

_validate_cc_target() {
  local target_arch="$1"
  local mode="${2:-smoke}"
  local cc_path cc_dump expected_pattern cc_pattern cc_machine
  local cc_obj cc_exe

  cc_path="$(update-alternatives --query cc 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
  [ -z "${cc_path}" ] && cc_path="$(command -v cc 2>/dev/null || true)"

  if [ -z "${cc_path}" ] || [ ! -x "${cc_path}" ]; then
    if [ "${mode}" = "hard-fail" ]; then
      echo "ERROR: /usr/bin/cc not found or not executable" >&2; exit 1
    else
      validate_fail "cc-missing" "/usr/bin/cc not found or not executable"
      return 0
    fi
  fi

  case "${target_arch}" in
    amd64) expected_pattern="x86_64" ;;
    arm64) expected_pattern="aarch64" ;;
    riscv64) expected_pattern="riscv64" ;;
    *) expected_pattern="" ;;
  esac
  cc_pattern="$(arch_elf_machine_grep_for "${target_arch}" 2>/dev/null || true)"

  cc_dump="$(cc -dumpmachine 2>/dev/null || true)"
  if [ -z "${cc_dump}" ]; then
    if [ "${mode}" = "hard-fail" ]; then
      echo "ERROR: /usr/bin/cc (${cc_path}) exists but 'cc -dumpmachine' returned empty — binary may be the wrong architecture" >&2
      if command -v file >/dev/null 2>&1; then
        echo "Binary type: $(file "${cc_path}" 2>/dev/null || true)" >&2
      fi
      exit 1
    else
      validate_fail "cc-dumpmachine" "/usr/bin/cc dumpmachine empty"
      return 0
    fi
  fi

  if [ -n "${expected_pattern}" ]; then
    if ! echo "${cc_dump}" | grep -q "^${expected_pattern}"; then
      if [ "${mode}" = "hard-fail" ]; then
        echo "ERROR: /usr/bin/cc dumpmachine '${cc_dump}' does not match target arch ${target_arch}" >&2
        exit 1
      else
        validate_fail "cc-arch" "/usr/bin/cc (${cc_path}) dumpmachine '${cc_dump}' != expected ${expected_pattern} for ${target_arch}"
        return 0
      fi
    fi
    echo "Verified /usr/bin/cc target: ${cc_dump} (expected ${target_arch})"
  fi

  if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
    cc_machine="$(readelf -h "${cc_path}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
    if [ -z "${cc_machine}" ]; then
      if [ "${mode}" = "hard-fail" ]; then
        echo "ERROR: cannot read ELF machine type of cc (${cc_path})" >&2
        exit 1
      else
        validate_fail "cc-elf" "cannot read ELF machine of cc"
        return 0
      fi
    fi
    case "${cc_machine}" in
      *"${cc_pattern}"*)
        echo "Verified /usr/bin/cc ELF machine: '${cc_machine}' matches ${target_arch}" ;;
      *)
        if [ "${mode}" = "hard-fail" ]; then
          echo "ERROR: /usr/bin/cc (${cc_path}) ELF machine '${cc_machine}' does not match '${cc_pattern}' for ${target_arch}" >&2
          exit 1
        else
          validate_fail "cc-elf" "ELF machine '${cc_machine}' != '${cc_pattern}' for ${target_arch}"
          return 0
        fi
        ;;
    esac
  fi

  local _cc1_tmpdir; _cc1_tmpdir="$(mktemp -d)"
  cc_obj="${_cc1_tmpdir}/cc1smoke.o"
  local _cc1_log="${_cc1_tmpdir}/cc1smoke.log"
  if printf 'int answer(void){return 42;}\n' | cc -x c - -c -o "${cc_obj}" 2>"${_cc1_log}"; then
    echo "Verified /usr/bin/cc cc1 compile-to-object smoke for ${target_arch}"
    if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
      local obj_machine
      obj_machine="$(readelf -h "${cc_obj}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
      case "${obj_machine}" in
        *"${cc_pattern}"*) echo "Verified cc1 output object ELF machine '${obj_machine}' matches ${target_arch}" ;;
        *)
          if [ "${mode}" = "hard-fail" ]; then
            echo "ERROR: cc1 produced object with ELF machine '${obj_machine}', expected '${cc_pattern}' for ${target_arch}" >&2; rm -rf "${_cc1_tmpdir}"; exit 1
          else
            validate_fail "cc1-obj-elf" "object ELF machine '${obj_machine}' != '${cc_pattern}'"
          fi
          ;;
      esac
    fi
  else
    if [ "${mode}" = "hard-fail" ]; then
      echo "ERROR: cc1 compile-to-object smoke FAILED for ${target_arch}:" >&2
      cat "${_cc1_log}" >&2 || true
      rm -rf "${_cc1_tmpdir}"
      exit 1
    else
      validate_fail "cc1-smoke" "cc1 compile-to-object smoke failed for ${target_arch}"
    fi
  fi
  rm -rf "${_cc1_tmpdir}"

  local _cc_link_tmpdir; _cc_link_tmpdir="$(mktemp -d)"
  cc_exe="${_cc_link_tmpdir}/cclinksmoke"
  local _cc_link_log="${_cc_link_tmpdir}/cclinksmoke.log"
  if printf 'int main(void){return 0;}\n' | cc -x c - -o "${cc_exe}" 2>"${_cc_link_log}"; then
    echo "Verified /usr/bin/cc link smoke for ${target_arch}"
  else
    if [ "${mode}" = "hard-fail" ]; then
      echo "ERROR: cc link smoke FAILED for ${target_arch} (missing crt/startup files?):" >&2
      cat "${_cc_link_log}" >&2 || true
      rm -rf "${_cc_link_tmpdir}"
      exit 1
    else
      validate_fail "cc-link" "cc link smoke failed for ${target_arch}"
    fi
  fi
  rm -rf "${_cc_link_tmpdir}"
}

validate_smoke() {
  local gcc_ver="${GCC_VERSION:-16.1.0}"
  local llvm_ver="${LLVM_RELEASE:-22.1.6}"
  local target_arch errors gcc_ver_out clang_ver_out

  target_arch="$(validate_resolve_arch)"
  echo "=== smoke: target_arch=${target_arch} ==="
  _VALIDATE_ERRORS=0

  _validate_cc_target "${target_arch}" smoke

  # --- gcc version ---
  gcc_ver_out="$(gcc --version 2>/dev/null | head -1 || true)"
  if echo "${gcc_ver_out}" | grep -q "${gcc_ver}"; then
    echo "SMOKE OK: gcc reports ${gcc_ver_out}"
  else
    validate_fail "gcc-version" "gcc --version: ${gcc_ver_out:-MISSING} (expected ${gcc_ver})"
  fi

  # --- clang version ---
  clang_ver_out="$(clang --version 2>/dev/null | head -1 || true)"
  if echo "${clang_ver_out}" | grep -q "${llvm_ver}"; then
    echo "SMOKE OK: clang reports ${clang_ver_out}"
  else
    validate_fail "clang-version" "clang --version: ${clang_ver_out:-MISSING} (expected ${llvm_ver})"
  fi

  # --- compiled library GCC signatures ---
  echo "=== smoke: checking compiled library compiler signatures ==="
  local gcc_sig_ok=0 libdir lib comment
  for libdir in \
    /opt/opencv5/lib \
    /opt/gstreamer/lib \
    /opt/ffmpeg/lib \
    /opt/libcamera/lib \
    /usr/local/lib; do
    [ -d "${libdir}" ] || continue
    for lib in $(find "${libdir}" -maxdepth 1 \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null | head -5); do
      [ -f "${lib}" ] || continue
      comment="$(readelf -p .comment "${lib}" 2>/dev/null || true)"
      if echo "${comment}" | grep -q "GCC: (GNU) ${gcc_ver}"; then
        echo "SMOKE OK: ${lib} compiled with GCC ${gcc_ver}"
        gcc_sig_ok=1
        break 2
      fi
    done
  done
  if [ "${gcc_sig_ok}" -eq 0 ]; then
    echo "SMOKE NOTE: no GCC ${gcc_ver} .comment signature found in sampled libs (may be clang-built or stripped)"
  fi

  # --- compiled library Clang signatures ---
  local clang_sig_ok=0
  for libdir in /usr/local/llvm-target/lib /usr/local/lib; do
    [ -d "${libdir}" ] || continue
    for lib in $(find "${libdir}" -maxdepth 2 \( -name '*.so' -o -name '*.a' \) 2>/dev/null | head -10); do
      [ -f "${lib}" ] || continue
      comment="$(readelf -p .comment "${lib}" 2>/dev/null || true)"
      if echo "${comment}" | grep -q "clang version ${llvm_ver}"; then
        echo "SMOKE OK: ${lib} compiled with Clang ${llvm_ver}"
        clang_sig_ok=1
        break 2
      fi
    done
  done
  if [ "${clang_sig_ok}" -eq 0 ]; then
    echo "SMOKE NOTE: no Clang ${llvm_ver} .comment signature found (libraries may be GCC-built)"
  fi

  # --- symlink chains ---
  local tool alt_val expected pair expected_bin
  for pair in "cc:gcc" "c++:g++" "gcc:gcc" "g++:g++"; do
    tool="${pair%%:*}"
    expected_bin="${pair##*:}"
    alt_val="$(update-alternatives --query "${tool}" 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
    expected="/opt/gcc-${gcc_ver}/bin/${expected_bin}"
    if [ -n "${alt_val}" ] && [ "${alt_val}" != "${expected}" ]; then
      validate_fail "symlink-${tool}" "alternatives ${tool} = ${alt_val} (expected ${expected})"
    elif [ -z "${alt_val}" ]; then
      validate_fail "symlink-${tool}" "no alternatives entry for ${tool}"
    else
      echo "SMOKE OK: ${tool} -> ${alt_val}"
    fi
  done

  local clang_alt
  clang_alt="$(update-alternatives --query clang 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
  if [ -n "${clang_alt}" ] && [ "${clang_alt}" = "/usr/local/llvm-target/bin/clang" ]; then
    echo "SMOKE OK: clang -> ${clang_alt}"
  else
    validate_fail "symlink-clang" "alternatives clang = ${clang_alt:-MISSING} (expected /usr/local/llvm-target/bin/clang)"
  fi

  # --- optional runtime payloads ---
  local payload
  for payload in \
    /usr/local/lib/onnxruntime-genai \
    /usr/local/lib/onnxruntime-gpu \
    /usr/local/include/tflite \
    /usr/local/include/tensorflow \
    /usr/local/lib/pkgconfig/litert.pc; do
    if [ -e "${payload}" ]; then
      echo "SMOKE OK: payload ${payload}"
    else
      validate_fail "payload-${payload##*/}" "optional payload missing: ${payload}"
    fi
  done

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "SMOKE FAILED: ${_VALIDATE_ERRORS} check(s) failed" >&2
    exit 1
  fi
  echo "SMOKE PASSED: all checks OK for ${target_arch}"
}

_VALIDATE_ERRORS=0

main() {
  local mode="${1:-}"
  case "${mode}" in
    artifact-source) validate_artifact_source ;;
    package) validate_package ;;
    smoke) validate_smoke ;;
    *)
      echo "Usage: $0 <artifact-source|package|smoke>" >&2
      exit 1
      ;;
  esac
}

main "$@"
