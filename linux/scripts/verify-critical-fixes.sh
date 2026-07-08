#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"
# Reuse the shared pass/fail/smoke_summary harness instead of a local copy.
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${REPO_ROOT}/linux/scripts/06-packaging/smoke-common.sh"

fix1_python_pc() {
  echo "--- Fix 1: gst-python staged libpython (python pkg-config rewrite) ---"
  local found=0 arch pc
  for arch in $(arch_list_to_words "${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}"); do
    pc="/opt/python-cross/${arch}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR:-3.14}.pc"
    if [ -f "${pc}" ]; then
      found=1
      if grep -q '^prefix=/opt/python-cross' "${pc}"; then
        pass "python-3.14.pc prefix points to /opt/python-cross (${arch})"
      else
        fail "python-3.14.pc prefix does NOT point to /opt/python-cross (${arch})"
      fi
      if grep -q '^libdir=/opt/python-cross' "${pc}" 2>/dev/null || \
         grep -q 'libdir=${prefix}/lib' "${pc}" 2>/dev/null; then
        pass "python-3.14.pc libdir resolves inside staging tree (${arch})"
      else
        fail "python-3.14.pc libdir may point outside staging tree (${arch})"
      fi
    fi
  done
  [ "${found}" -eq 0 ] && echo "  SKIP: no per-arch python-3.14.pc found (not in cross-compiler context)"
}

fix2_abseil_span() {
  echo "--- Fix 2: libcamera abseil header in LiteRT ---"
  local dirs=(
    "/opt/litert/include"
    "/usr/local/include/tensorflow/lite"
    "/usr/local/include/litert"
  )
  local found=0 dir
  for dir in "${dirs[@]}"; do
    if [ -f "${dir}/absl/types/span.h" ]; then
      pass "absl/types/span.h found in ${dir}"
      found=1
      break
    fi
  done
  if [ "${found}" -eq 0 ]; then
    for dir in "${dirs[@]}"; do
      if [ -d "${dir}" ]; then
        if find "${dir}" -name "span.h" -path "*/absl/types/*" 2>/dev/null | grep -q .; then
          pass "absl/types/span.h found via search in ${dir}"
          found=1
          break
        fi
      fi
    done
  fi
  if [ "${found}" -eq 0 ]; then
    if [ -d "/opt/litert" ] || [ -d "/usr/local/include/tensorflow" ]; then
      fail "absl/types/span.h NOT found in any LiteRT include directory"
    else
      echo "  SKIP: no LiteRT include directories found"
    fi
  fi
}

fix3_libdynload_dangling() {
  echo "--- Fix 3: cross lib-dynload no dangling symlinks ---"
  local dir="/opt/python-cross/lib/python${PYTHON_MAJOR_MINOR:-3.14}/lib-dynload"
  if [ -d "${dir}" ]; then
    local count
    count=$(find "${dir}" -xtype l 2>/dev/null | wc -l)
    if [ "${count}" -eq 0 ]; then
      pass "No dangling symlinks in ${dir}"
    else
      fail "${count} dangling symlinks found in ${dir}"
      find "${dir}" -xtype l 2>/dev/null | while read -r sl; do
        echo "    dangling: ${sl}" >&2
      done
    fi
  else
    echo "  SKIP: ${dir} not found (not in cross-compiler context)"
  fi
}

fix4_cc_dumpmachine() {
  echo "--- Fix 4: cross GCC architecture guard (cc target triple) ---"
  local arch
  arch="$(canonical_target_arch "${TARGET_ARCH:-${TARGETARCH:-}}" 2>/dev/null || true)"
  if [ -n "${arch}" ]; then
    local expected
    expected="$(arch_uname_name_for "${arch}")"
    if command -v cc >/dev/null 2>&1; then
      local actual
      actual="$(cc -dumpmachine 2>/dev/null | cut -d- -f1 || echo '')"
      if [ "${actual}" = "${expected}" ]; then
        pass "cc -dumpmachine reports ${actual} (expected ${expected})"
      else
        fail "cc -dumpmachine reports ${actual} (expected ${expected})"
      fi
      if command -v readelf >/dev/null 2>&1; then
        local cc_bin elf_expected elf_actual
        cc_bin="$(command -v cc)"
        elf_expected="$(arch_elf_machine_grep_for "${arch}" 2>/dev/null || echo '')"
        elf_actual="$(elf_machine_name "${cc_bin}" 2>/dev/null || echo '')"
        if [ -n "${elf_expected}" ] && echo "${elf_actual}" | grep -qF "${elf_expected}"; then
          pass "cc ELF machine matches expected ${elf_expected}"
        elif [ -n "${elf_actual}" ]; then
          fail "cc ELF machine is ${elf_actual} (expected ${elf_expected})"
        fi
      fi
    else
      echo "  SKIP: cc not found"
    fi
  else
    echo "  SKIP: cannot determine target arch"
  fi
}

fix5_gst_geometry_include() {
  echo "--- Fix 5: OpenCV 5 GStreamer compat (geometry.hpp include) ---"
  local dirs=(
    "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer"
    "/opt/scripts/03-media/build/gstreamer"
  )
  local found=0 src="" dir
  for dir in "${dirs[@]}"; do
    if [ -d "${dir}" ]; then
      src="$(find "${dir}" -name "gstsegmentation.cpp" -type f 2>/dev/null | head -1 || echo '')"
      if [ -n "${src}" ] && [ -f "${src}" ]; then
        found=1
        break
      fi
    fi
  done
  if [ "${found}" -eq 1 ]; then
    if grep -q '#include <opencv2/geometry.hpp>' "${src}" 2>/dev/null; then
      pass "gstsegmentation.cpp includes opencv2/geometry.hpp"
    else
      fail "gstsegmentation.cpp missing #include <opencv2/geometry.hpp>"
      echo "  Source: ${src}" >&2
    fi
  else
    echo "  SKIP: gstsegmentation.cpp not found (checking if patch applies at build time)"
    if [ -f "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh" ]; then
      if grep -q "geometry.hpp" "${REPO_ROOT}/linux/scripts/03-media/build/gstreamer/common/patch-gstreamer-sources.sh" 2>/dev/null; then
        pass "patch-gstreamer-sources.sh contains geometry.hpp patch"
      else
        fail "patch-gstreamer-sources.sh missing geometry.hpp reference"
      fi
    fi
  fi
}

fix6_native_gcc_system_paths() {
  echo "--- Fix 6: native-GCC system header/lib paths for torch-venv source builds ---"
  # Locks in bugs D & E from the 2026-07 cross rebuild (see
  # docs/cross-build-verification.md). The relocated native GCC/G++ cannot find
  # /usr/include for QEMU source builds; the canonical helper is
  # append_cross_idirafter in 01-core/common.sh, inlined here in the torch/android
  # stages to avoid pulling common.sh's dependency chain into them.
  local stv="${REPO_ROOT}/linux/scripts/06-packaging/setup-torch-venv.sh"
  local swp="${REPO_ROOT}/linux/scripts/06-packaging/swap-native-gcc.sh"
  local dep="${REPO_ROOT}/linux/scripts/03-media/runtime/install-deps.sh"

  # D: -idirafter must reach C AND C++ compiles in both the in-script env and the
  # persisted profile.d (CPATH alone does not fix C++ #include_next).
  if grep -q 'idirafter /usr/include' "${stv}" 2>/dev/null && \
     grep -qE 'export CXXFLAGS=.*idaf|CXXFLAGS.*idirafter' "${stv}" 2>/dev/null; then
    pass "setup-torch-venv.sh injects -idirafter into CXXFLAGS (C++ #include_next)"
  else
    fail "setup-torch-venv.sh lost the -idirafter CXXFLAGS injection (bug D regression)"
  fi
  if grep -q 'idirafter /usr/include' "${swp}" 2>/dev/null; then
    pass "swap-native-gcc.sh profile.d writes -idirafter system paths"
  else
    fail "swap-native-gcc.sh lost the -idirafter profile.d injection (bug D regression)"
  fi
  # D: Pillow needs jpeglib.h -> libjpeg-dev in the final-stage target packages.
  if grep -qE '^[[:space:]]*libjpeg-dev' "${dep}" 2>/dev/null; then
    pass "install-deps.sh installs libjpeg-dev (Pillow jpeglib.h)"
  else
    fail "install-deps.sh no longer installs libjpeg-dev (bug D regression)"
  fi
  # E: apt numpy must NOT be seeded into the venv (collides with uv's built wheel).
  if grep -qE 'for pkg in .*\bnumpy\b' "${stv}" 2>/dev/null; then
    fail "setup-torch-venv.sh re-seeds apt numpy into the venv (bug E regression)"
  else
    pass "setup-torch-venv.sh does not seed apt numpy into the venv"
  fi
}

echo "=== Critical Fixes Regression Tests ==="
echo ""

FIX_FUNCS=(fix1_python_pc fix2_abseil_span fix3_libdynload_dangling fix4_cc_dumpmachine fix5_gst_geometry_include fix6_native_gcc_system_paths)
for _fix_fn in "${FIX_FUNCS[@]}"; do
  "${_fix_fn}"
  echo ""
done

smoke_summary
