#!/usr/bin/env bash
set -euo pipefail

# smoke-wrapper.sh
# Hard-fail smoke verification for the runtime wrapper image.
# Delegates compiler validation to validate-compilers.sh smoke mode.
#
# Expected environment:
#   GCC_VERSION        e.g. "16.1.0"
#   LLVM_RELEASE       e.g. "22.1.6"
#   TARGET_ARCH        amd64, arm64, or riscv64
#   TARGETARCH         fallback for TARGET_ARCH

VALIDATE_COMPILERS="/opt/scripts/packaging/validate-compilers.sh"

main() {
  local gcc_ver="${GCC_VERSION:-16.1.0}"
  local llvm_ver="${LLVM_RELEASE:-22.1.6}"
  local target_arch errors

  target_arch="${TARGET_ARCH:-${TARGETARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}}"
  if [ -f /opt/scripts/core/platform.sh ]; then
    source /opt/scripts/core/platform.sh
    target_arch="$(arch_normalize "${target_arch}")"
  else
    case "${target_arch}" in
      x86_64) target_arch=amd64 ;;
      aarch64) target_arch=arm64 ;;
    esac
  fi

  echo "=== smoke: target_arch=${target_arch} ==="
  errors=0
  fail() { echo "SMOKE FAIL [$1]: $2" >&2; errors=$((errors + 1)); }

  # --- delegate compiler checks to validate-compilers.sh smoke mode ---
  if [ -x "${VALIDATE_COMPILERS}" ]; then
    echo "=== smoke: running shared compiler validation ==="
    GCC_VERSION="${gcc_ver}" \
    LLVM_RELEASE="${llvm_ver}" \
    TARGET_ARCH="${target_arch}" \
    bash "${VALIDATE_COMPILERS}" smoke || {
      echo "SMOKE FAIL: shared compiler validation failed" >&2
      exit 1
    }
    echo "=== smoke: shared compiler validation passed ==="
  else
    # Fallback inline checks if the shared script is unavailable
    echo "=== smoke: validate-compilers.sh not found; running inline checks ==="

    # --- cc architecture guard ---
    local cc_path cc_dump expected_prefix
    cc_path="$(update-alternatives --query cc 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
    [ -z "${cc_path}" ] && cc_path="$(command -v cc 2>/dev/null || true)"
    if [ -n "${cc_path}" ] && [ -x "${cc_path}" ]; then
      cc_dump="$(cc -dumpmachine 2>/dev/null || true)"
      case "${target_arch}" in
        amd64)   expected_prefix="x86_64" ;;
        arm64)   expected_prefix="aarch64" ;;
        riscv64) expected_prefix="riscv64" ;;
        *)       expected_prefix="" ;;
      esac
      if [ -n "${expected_prefix}" ] && ! echo "${cc_dump}" | grep -q "^${expected_prefix}"; then
        fail "cc-arch" "/usr/bin/cc (${cc_path}) dumpmachine '${cc_dump}' != expected ${expected_prefix} for ${target_arch}"
      else
        echo "SMOKE OK: cc dumpmachine '${cc_dump}' matches ${target_arch}"
      fi
    else
      fail "cc-missing" "/usr/bin/cc not found or not executable"
    fi

    # --- gcc version ---
    local gcc_ver_out
    gcc_ver_out="$(gcc --version 2>/dev/null | head -1 || true)"
    if echo "${gcc_ver_out}" | grep -q "${gcc_ver}"; then
      echo "SMOKE OK: gcc reports ${gcc_ver_out}"
    else
      fail "gcc-version" "gcc --version: ${gcc_ver_out:-MISSING} (expected ${gcc_ver})"
    fi

    # --- clang version ---
    local clang_ver_out
    clang_ver_out="$(clang --version 2>/dev/null | head -1 || true)"
    if echo "${clang_ver_out}" | grep -q "${llvm_ver}"; then
      echo "SMOKE OK: clang reports ${clang_ver_out}"
    else
      fail "clang-version" "clang --version: ${clang_ver_out:-MISSING} (expected ${llvm_ver})"
    fi

    # --- symlink chains ---
    local tool alt_val expected pair expected_bin
    for pair in "cc:gcc" "c++:g++" "gcc:gcc" "g++:g++"; do
      tool="${pair%%:*}"
      expected_bin="${pair##*:}"
      alt_val="$(update-alternatives --query "${tool}" 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
      expected="/opt/gcc-${gcc_ver}/bin/${expected_bin}"
      if [ -n "${alt_val}" ] && [ "${alt_val}" != "${expected}" ]; then
        fail "symlink-${tool}" "alternatives ${tool} = ${alt_val} (expected ${expected})"
      elif [ -z "${alt_val}" ]; then
        fail "symlink-${tool}" "no alternatives entry for ${tool}"
      else
        echo "SMOKE OK: ${tool} -> ${alt_val}"
      fi
    done

    local clang_alt
    clang_alt="$(update-alternatives --query clang 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
    if [ -n "${clang_alt}" ] && [ "${clang_alt}" = "/usr/local/llvm-target/bin/clang" ]; then
      echo "SMOKE OK: clang -> ${clang_alt}"
    else
      fail "symlink-clang" "alternatives clang = ${clang_alt:-MISSING} (expected /usr/local/llvm-target/bin/clang)"
    fi
  fi

  # --- compiled library GCC signatures ---
  echo "=== smoke: checking compiled library compiler signatures ==="
  local gcc_sig_ok=0 libdir lib comment
  for libdir in \
    /opt/opencv4/lib \
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
      fail "payload-${payload##*/}" "optional payload missing: ${payload}"
    fi
  done

  # --- hard-fail if any checks failed ---
  if [ "${errors}" -gt 0 ]; then
    echo "SMOKE FAILED: ${errors} check(s) failed" >&2
    exit 1
  fi
  echo "SMOKE PASSED: all checks OK for ${target_arch}"
}

main "$@"
