#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

FAILURES=0

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

echo "=== Five Critical Fixes Regression Tests ==="
echo ""

# Fix 1: gst-python staged libpython — python-3.14.pc must have correct libdir/includedir
# pointing into the cross-compiler's staging tree, not the build host prefix.
echo "--- Fix 1: gst-python staged libpython (python pkg-config rewrite) ---"
FIX1_FOUND=0
for _fix1_arch in amd64 arm64 riscv64; do
  FIX1_PC="/opt/python-cross/${_fix1_arch}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR:-3.14}.pc"
  if [ -f "${FIX1_PC}" ]; then
    FIX1_FOUND=1
    if grep -q '^prefix=/opt/python-cross' "${FIX1_PC}"; then
      pass "python-3.14.pc prefix points to /opt/python-cross (${_fix1_arch})"
    else
      fail "python-3.14.pc prefix does NOT point to /opt/python-cross (${_fix1_arch})"
    fi
    if grep -q '^libdir=/opt/python-cross' "${FIX1_PC}" 2>/dev/null || \
       grep -q 'libdir=${prefix}/lib' "${FIX1_PC}" 2>/dev/null; then
      pass "python-3.14.pc libdir resolves inside staging tree (${_fix1_arch})"
    else
      fail "python-3.14.pc libdir may point outside staging tree (${_fix1_arch})"
    fi
  fi
done
if [ "${FIX1_FOUND}" -eq 0 ]; then
  echo "  SKIP: no per-arch python-3.14.pc found (not in cross-compiler context)"
fi

echo ""

# Fix 2: libcamera abseil — absl/types/span.h must exist in LiteRT installation dir.
echo "--- Fix 2: libcamera abseil header in LiteRT ---"
FIX2_DIRS=(
  "/opt/litert/include"
  "/usr/local/include/tensorflow/lite"
  "/usr/local/include/litert"
)
FIX2_FOUND=0
for dir in "${FIX2_DIRS[@]}"; do
  if [ -f "${dir}/absl/types/span.h" ]; then
    pass "absl/types/span.h found in ${dir}"
    FIX2_FOUND=1
    break
  fi
done
if [ "${FIX2_FOUND}" -eq 0 ]; then
  for dir in "${FIX2_DIRS[@]}"; do
    if [ -d "${dir}" ]; then
      if find "${dir}" -name "span.h" -path "*/absl/types/*" 2>/dev/null | grep -q .; then
        pass "absl/types/span.h found via search in ${dir}"
        FIX2_FOUND=1
        break
      fi
    fi
  done
fi
if [ "${FIX2_FOUND}" -eq 0 ]; then
  if [ -d "/opt/litert" ] || [ -d "/usr/local/include/tensorflow" ]; then
    fail "absl/types/span.h NOT found in any LiteRT include directory"
  else
    echo "  SKIP: no LiteRT include directories found"
  fi
fi

echo ""

# Fix 3: cross lib-dynload — zero dangling symlinks in Python lib-dynload directory.
echo "--- Fix 3: cross lib-dynload no dangling symlinks ---"
FIX3_DIR="/opt/python-cross/lib/python${PYTHON_MAJOR_MINOR:-3.14}/lib-dynload"
if [ -d "${FIX3_DIR}" ]; then
  DANGLING_COUNT=$(find "${FIX3_DIR}" -xtype l 2>/dev/null | wc -l)
  if [ "${DANGLING_COUNT}" -eq 0 ]; then
    pass "No dangling symlinks in ${FIX3_DIR}"
  else
    fail "${DANGLING_COUNT} dangling symlinks found in ${FIX3_DIR}"
    find "${FIX3_DIR}" -xtype l 2>/dev/null | while read -r sl; do
      echo "    dangling: ${sl}" >&2
    done
  fi
else
  echo "  SKIP: ${FIX3_DIR} not found (not in cross-compiler context)"
fi

echo ""

# Fix 4: cross GCC architecture guard — cc -dumpmachine must match TARGET_ARCH.
echo "--- Fix 4: cross GCC architecture guard (cc target triple) ---"
FIX4_ARCH="$(canonical_target_arch "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || true)"
if [ -n "${FIX4_ARCH}" ]; then
  FIX4_EXPECTED="$(arch_uname_name_for "${FIX4_ARCH}")"
  if command -v cc >/dev/null 2>&1; then
    FIX4_ACTUAL="$(cc -dumpmachine 2>/dev/null | cut -d- -f1 || echo '')"
    if [ "${FIX4_ACTUAL}" = "${FIX4_EXPECTED}" ]; then
      pass "cc -dumpmachine reports ${FIX4_ACTUAL} (expected ${FIX4_EXPECTED})"
    else
      fail "cc -dumpmachine reports ${FIX4_ACTUAL} (expected ${FIX4_EXPECTED})"
    fi
    if command -v readelf >/dev/null 2>&1; then
      FIX4_CC="$(command -v cc)"
      FIX4_ELF_EXPECTED="$(arch_elf_machine_grep_for "${FIX4_ARCH}" 2>/dev/null || echo '')"
      FIX4_ELF="$(elf_machine_name "${FIX4_CC}" 2>/dev/null || echo '')"
      if [ -n "${FIX4_ELF_EXPECTED}" ] && echo "${FIX4_ELF}" | grep -qF "${FIX4_ELF_EXPECTED}"; then
        pass "cc ELF machine matches expected ${FIX4_ELF_EXPECTED}"
      elif [ -n "${FIX4_ELF}" ]; then
        fail "cc ELF machine is ${FIX4_ELF} (expected ${FIX4_ELF_EXPECTED})"
      fi
    fi
  else
    echo "  SKIP: cc not found"
  fi
else
  echo "  SKIP: cannot determine target arch"
fi

echo ""

# Fix 5: OpenCV 5 GStreamer compat — gstsegmentation.cpp must include geometry.hpp.
echo "--- Fix 5: OpenCV 5 GStreamer compat (geometry.hpp include) ---"
FIX5_DIRS=(
  "${REPO_ROOT}/linux/scripts/media/build/gstreamer"
  "/opt/scripts/media/build/gstreamer"
)
FIX5_FOUND=0
FIX5_SRC=""
for dir in "${FIX5_DIRS[@]}"; do
  if [ -d "${dir}" ]; then
    FIX5_SRC="$(find "${dir}" -name "gstsegmentation.cpp" -type f 2>/dev/null | head -1 || echo '')"
    if [ -n "${FIX5_SRC}" ] && [ -f "${FIX5_SRC}" ]; then
      FIX5_FOUND=1
      break
    fi
  fi
done
if [ "${FIX5_FOUND}" -eq 1 ]; then
  if grep -q '#include <opencv2/geometry.hpp>' "${FIX5_SRC}" 2>/dev/null; then
    pass "gstsegmentation.cpp includes opencv2/geometry.hpp"
  else
    fail "gstsegmentation.cpp missing #include <opencv2/geometry.hpp>"
    echo "  Source: ${FIX5_SRC}" >&2
  fi
else
  echo "  SKIP: gstsegmentation.cpp not found (checking if patch applies at build time)"
  if [ -f "${REPO_ROOT}/linux/scripts/media/build/gstreamer/common/patch-gstreamer-sources.sh" ]; then
    if grep -q "geometry.hpp" "${REPO_ROOT}/linux/scripts/media/build/gstreamer/common/patch-gstreamer-sources.sh" 2>/dev/null; then
      pass "patch-gstreamer-sources.sh contains geometry.hpp patch"
    else
      fail "patch-gstreamer-sources.sh missing geometry.hpp reference"
    fi
  fi
fi

echo ""
echo "=== Results: ${FAILURES} failure(s) ==="

[ "${FAILURES}" -eq 0 ] || exit 1
