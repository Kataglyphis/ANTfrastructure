#!/usr/bin/env bash
set -euo pipefail

# validate-compilers.sh
# Unified compiler chain validation for GCC 16.1.0 and Clang 22.1.6.
# Called from Dockerfile.package and smoke-wrapper.sh.
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
source "${_vcs_script_dir}/../01-core/platform.sh"

validate_resolve_arch() {
  local raw="${1:-${TARGET_ARCH:-${TARGETARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}}}"
  arch_normalize "${raw}"
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

  # cross compilers
  local cross_arch triplet cross_gcc cross_ver
  for cross_arch in arm64 riscv64; do
    [ "${cross_arch}" = "${target_arch}" ] && continue
    case "${cross_arch}" in
      arm64) triplet="aarch64-linux-gnu" ;;
      riscv64) triplet="riscv64-linux-gnu" ;;
      *) continue ;;
    esac
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
    if [ -d /usr/local/llvm-target ]; then
      ln -s /usr/local/llvm-target /opt/llvm-target
    elif [ "${target_arch}" = "amd64" ] && [ -d /usr/local/llvm-22 ]; then
      ln -s /usr/local/llvm-22 /opt/llvm-target
    fi
  fi
  if [ -x "${llvm_target}" ]; then
    local clang_ver clang_major_minor
    clang_ver="$("${llvm_target}" --version 2>/dev/null | head -1 || true)"
    if echo "${clang_ver}" | grep -q "${LLVM_RELEASE:-22.1.6}"; then
      echo "OK: target clang ${llvm_target} reports ${clang_ver}"
    else
      # Check major.minor match (artifact may have minor patch drift)
      clang_major_minor="$(echo "${LLVM_RELEASE:-22.1.6}" | cut -d. -f1-2)"
      if echo "${clang_ver}" | grep -q "clang version ${clang_major_minor}"; then
        echo "OK: target clang ${llvm_target} reports ${clang_ver} (major.minor ${clang_major_minor} matches)"
      else
        validate_fail "target-clang" "${llvm_target} --version: ${clang_ver:-MISSING} (expected ${LLVM_RELEASE:-22.1.6})"
      fi
    fi
  elif [ "${BUILD_MODE:-native}" = "cross" ] && [ -d /opt/llvm-target ]; then
    validate_fail "target-clang-missing" "${llvm_target} not executable in /opt/llvm-target"
  else
    echo "WARNING: missing target-native LLVM toolchain for ${target_arch}; continuing with distro LLVM"
    mkdir -p /opt/llvm-target
  fi

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "ARTIFACT COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
  echo "ARTIFACT COMPILER VERIFICATION PASSED for ${target_arch}"
}

validate_package() {
  local target_arch gcc_prefix cc_path cc_dump expected_pattern
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

  # --- cc -dumpmachine hard-fail guard ---
  cc_path="$(update-alternatives --query cc 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
  [ -z "${cc_path}" ] && cc_path="$(command -v cc 2>/dev/null || true)"
  if [ -n "${cc_path}" ] && [ -x "${cc_path}" ]; then
    cc_dump="$(cc -dumpmachine 2>/dev/null || true)"
    if [ -z "${cc_dump}" ]; then
      echo "ERROR: /usr/bin/cc (${cc_path}) exists but 'cc -dumpmachine' returned empty — binary may be the wrong architecture" >&2
      if command -v file >/dev/null 2>&1; then
        echo "Binary type: $(file "${cc_path}" 2>/dev/null || true)" >&2
      fi
      exit 1
    fi
    case "${target_arch}" in
      amd64) expected_pattern="x86_64" ;;
      arm64) expected_pattern="aarch64" ;;
      riscv64) expected_pattern="riscv64" ;;
      *) expected_pattern="" ;;
    esac
    if [ -n "${expected_pattern}" ] && [ -n "${cc_dump}" ]; then
      if ! echo "${cc_dump}" | grep -q "^${expected_pattern}"; then
        echo "ERROR: /usr/bin/cc dumpmachine '${cc_dump}' does not match target arch ${target_arch}" >&2
        exit 1
      fi
      echo "Verified /usr/bin/cc target: ${cc_dump} (expected ${target_arch})"
    fi

    # --- ELF machine hard-fail guard ---
    # `cc -dumpmachine` reports the *target* triple and cannot distinguish a
    # target-native compiler binary from a host-arch cross-compiler that merely
    # targets this arch. The ELF machine type of the cc binary itself is the
    # real discriminator: in the final runtime image, cc MUST be a target-arch
    # binary.
    local cc_pattern cc_machine
    case "${target_arch}" in
      amd64) cc_pattern="X86-64" ;;
      arm64) cc_pattern="AArch64" ;;
      riscv64) cc_pattern="RISC-V" ;;
      *) cc_pattern="" ;;
    esac
    if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
      cc_machine="$(readelf -h "${cc_path}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
      if [ -z "${cc_machine}" ]; then
        echo "ERROR: cannot read ELF machine type of cc (${cc_path})" >&2
        exit 1
      fi
      case "${cc_machine}" in
        *"${cc_pattern}"*)
          echo "Verified /usr/bin/cc ELF machine: '${cc_machine}' matches ${target_arch}"
          ;;
        *)
          echo "ERROR: /usr/bin/cc (${cc_path}) ELF machine '${cc_machine}' does not match '${cc_pattern}' for ${target_arch}. A host-arch compiler leaked into the runtime image." >&2
          exit 1
          ;;
      esac
    fi

    # --- cc1 compile-to-object smoke ---
    # `cc --version` / `-dumpmachine` do not exercise cc1. Compile (not link) a
    # tiny TU to prove the back end actually works for the target. Under the
    # package stage this runs on the target platform (QEMU for foreign arch).
    local cc_obj
    cc_obj="$(mktemp -d)/cc1smoke.o"
    if printf 'int answer(void){return 42;}\n' | cc -x c - -c -o "${cc_obj}" 2>/tmp/cc1smoke.log; then
      echo "Verified /usr/bin/cc cc1 compile-to-object smoke for ${target_arch}"
      if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
        local obj_machine
        obj_machine="$(readelf -h "${cc_obj}" 2>/dev/null | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p' | head -n1)"
        case "${obj_machine}" in
          *"${cc_pattern}"*) echo "Verified cc1 output object ELF machine '${obj_machine}' matches ${target_arch}" ;;
          *) echo "ERROR: cc1 produced object with ELF machine '${obj_machine}', expected '${cc_pattern}' for ${target_arch}" >&2; exit 1 ;;
        esac
      fi
    else
      echo "ERROR: cc1 compile-to-object smoke FAILED for ${target_arch}:" >&2
      cat /tmp/cc1smoke.log >&2 || true
      exit 1
    fi
    rm -f "${cc_obj}" /tmp/cc1smoke.log 2>/dev/null || true

    # --- cc link smoke (crt files, Scrt1.o etc.) ---
    local cc_exe
    cc_exe="$(mktemp -d)/cclinksmoke"
    if printf 'int main(void){return 0;}\n' | cc -x c - -o "${cc_exe}" 2>/tmp/cclinksmoke.log; then
      echo "Verified /usr/bin/cc link smoke for ${target_arch}"
      rm -f "${cc_exe}"
    else
      echo "ERROR: cc link smoke FAILED for ${target_arch} (missing crt/startup files?):" >&2
      cat /tmp/cclinksmoke.log >&2 || true
      exit 1
    fi
    rm -f /tmp/cclinksmoke.log 2>/dev/null || true
  fi

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "PACKAGE COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
}

validate_smoke() {
  local gcc_ver="${GCC_VERSION:-16.1.0}"
  local llvm_ver="${LLVM_RELEASE:-22.1.6}"
  local target_arch errors cc_path cc_dump expected_prefix gcc_ver_out clang_ver_out

  target_arch="$(validate_resolve_arch)"
  echo "=== smoke: target_arch=${target_arch} ==="
  _VALIDATE_ERRORS=0

  # --- cc architecture guard ---
  cc_path="$(update-alternatives --query cc 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
  [ -z "${cc_path}" ] && cc_path="$(command -v cc 2>/dev/null || true)"
  if [ -n "${cc_path}" ] && [ -x "${cc_path}" ]; then
    cc_dump="$(cc -dumpmachine 2>/dev/null || true)"
    case "${target_arch}" in
      amd64) expected_prefix="x86_64" ;;
      arm64) expected_prefix="aarch64" ;;
      riscv64) expected_prefix="riscv64" ;;
      *) expected_prefix="" ;;
    esac
    if [ -n "${expected_prefix}" ] && ! echo "${cc_dump}" | grep -q "^${expected_prefix}"; then
      validate_fail "cc-arch" "/usr/bin/cc (${cc_path}) dumpmachine '${cc_dump}' != expected ${expected_prefix} for ${target_arch}"
    else
      echo "SMOKE OK: cc dumpmachine '${cc_dump}' matches ${target_arch}"
    fi
  else
    validate_fail "cc-missing" "/usr/bin/cc not found or not executable"
  fi

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
