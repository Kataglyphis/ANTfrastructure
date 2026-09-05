#!/usr/bin/env bash
set -euo pipefail
# smoke-critical-fixes.sh — the half of the critical-fixes battery that can only
# mean anything INSIDE a built image: the per-arch /opt/python-cross staging
# trees, the abseil headers LiteRT's own headers include, and the native cc's
# target triple. preflight owns the repo-grep half (verify-critical-fixes.sh).
# docs/cross-build-verification.md#the-in-image-half-of-critical-fixes

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/06-packaging/smoke-common.sh
source "${_SCRIPT_DIR}/smoke-common.sh"

CF_SMOKE_ROOT="${CF_SMOKE_ROOT:-}"
PYTHON_CROSS_ROOT="${CF_SMOKE_ROOT}/opt/python-cross"
LITERT_INCLUDE_DIRS=("${CF_SMOKE_ROOT}/usr/local/include" "${CF_SMOKE_ROOT}/opt/litert/include"
                     "${CF_SMOKE_ROOT}/usr/local/include/litert" "${CF_SMOKE_ROOT}/usr/local/include/tensorflow/lite")
LITERT_HEADER_DIRS=("${CF_SMOKE_ROOT}/usr/local/include/tflite" "${CF_SMOKE_ROOT}/usr/local/include/c"
                    "${CF_SMOKE_ROOT}/usr/local/include/tensorflow" "${CF_SMOKE_ROOT}/opt/litert/include")

# The .pc prefix a consumer's pkg-config resolves, with ${pcfiledir} expanded the
# way pkg-config expands it. A relocatable prefix is correct and a literal one is
# correct; only where it LANDS decides.
resolved_pc_prefix() {
  local pc="$1" raw dir
  raw="$(sed -n 's/^prefix=//p' "${pc}" | head -1)"
  [ -n "${raw}" ] || return 1
  dir="$(dirname "${pc}")"
  raw="${raw//\$\{pcfiledir\}/${dir}}"
  realpath -m "${raw}" 2>/dev/null || printf '%s' "${raw}"
}

fix1_python_pc() {
  echo "--- Fix 1: gst-python staged libpython (python pkg-config rewrite) ---"
  local found=0 arch pc prefix
  for arch in $(smoke_arch_words "${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}"); do
    pc="${PYTHON_CROSS_ROOT}/${arch}/usr/local/lib/pkgconfig/python-${PYTHON_MAJOR_MINOR:-3.14}.pc"
    if [ -f "${pc}" ]; then
      found=1
      prefix="$(resolved_pc_prefix "${pc}" || true)"
      case "${prefix}" in
        "${PYTHON_CROSS_ROOT}/${arch}"|"${PYTHON_CROSS_ROOT}/${arch}"/*)
          pass "python-${PYTHON_MAJOR_MINOR:-3.14}.pc prefix resolves to ${prefix} (${arch})" ;;
        *)
          fail "python-${PYTHON_MAJOR_MINOR:-3.14}.pc prefix resolves to '${prefix}', outside ${PYTHON_CROSS_ROOT}/${arch} (${arch})" ;;
      esac
      if grep -q "^libdir=${PYTHON_CROSS_ROOT}" "${pc}" 2>/dev/null || \
         grep -q 'libdir=${prefix}/lib' "${pc}" 2>/dev/null; then
        pass "python-${PYTHON_MAJOR_MINOR:-3.14}.pc libdir resolves inside staging tree (${arch})"
      else
        fail "python-${PYTHON_MAJOR_MINOR:-3.14}.pc libdir may point outside staging tree (${arch})"
      fi
    fi
  done
  { [ "${found}" -eq 0 ] && echo "  SKIP: no per-arch python-${PYTHON_MAJOR_MINOR:-3.14}.pc found (not a cross-compiler image)"; } || true
}

# The header that demands absl, so a missing absl is reported only where a
# consumer would actually hit it.
_absl_demander() {
  local dir hit
  for dir in "${LITERT_HEADER_DIRS[@]}"; do
    [ -d "${dir}" ] || continue
    hit="$(grep -rlm1 --include='*.h' -e 'include "absl/' "${dir}" 2>/dev/null | head -1 || true)"
    if [ -n "${hit}" ]; then
      printf '%s' "${hit}"
      return 0
    fi
  done
  return 0
}

fix2_abseil_span() {
  echo "--- Fix 2: abseil headers beside the LiteRT headers that include them ---"
  local dir demander
  for dir in "${LITERT_INCLUDE_DIRS[@]}"; do
    if [ -f "${dir}/absl/types/span.h" ]; then
      pass "absl/types/span.h found in ${dir}"
      return 0
    fi
  done
  demander="$(_absl_demander)"
  if [ -n "${demander}" ]; then
    fail "absl/types/span.h is in NO include dir, but ${demander} includes absl/ — a consumer compiling against the shipped LiteRT headers cannot build"
  else
    echo "  SKIP: no LiteRT headers that include absl/ are present"
  fi
}

fix3_libdynload_dangling() {
  echo "--- Fix 3: cross lib-dynload no dangling symlinks ---"
  local found=0 arch dir count
  for arch in $(smoke_arch_words "${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}"); do
    dir="${PYTHON_CROSS_ROOT}/${arch}/usr/local/lib/python${PYTHON_MAJOR_MINOR:-3.14}/lib-dynload"
    if [ -d "${dir}" ]; then
      found=1
      count=$(find "${dir}" -xtype l 2>/dev/null | wc -l)
      if [ "${count}" -eq 0 ]; then
        pass "No dangling symlinks in lib-dynload (${arch})"
      else
        fail "${count} dangling symlinks found in lib-dynload (${arch})"
        find "${dir}" -xtype l 2>/dev/null | while read -r sl; do
          echo "    dangling: ${sl}" >&2
        done
      fi
    fi
  done
  { [ "${found}" -eq 0 ] && echo "  SKIP: no per-arch lib-dynload found (not a cross-compiler image)"; } || true
}

fix4_cc_dumpmachine() {
  echo "--- Fix 4: native cc architecture guard (cc target triple) ---"
  local arch expected actual cc_bin elf_expected elf_actual
  arch="$(smoke_host_arch "${TARGET_ARCH:-${TARGETARCH:-}}")"
  if [ -z "${arch}" ]; then
    echo "  SKIP: cannot determine target arch"
    return 0
  fi
  if ! command -v cc >/dev/null 2>&1; then
    echo "  SKIP: cc not found"
    return 0
  fi
  expected="$(smoke_uname_name "${arch}")"
  actual="$(cc -dumpmachine 2>/dev/null | cut -d- -f1 || echo '')"
  if [ "${actual}" = "${expected}" ]; then
    pass "cc -dumpmachine reports ${actual} (expected ${expected})"
  else
    fail "cc -dumpmachine reports ${actual} (expected ${expected})"
  fi
  command -v readelf >/dev/null 2>&1 || return 0
  cc_bin="$(command -v cc)"
  elf_expected="$(smoke_elf_machine_grep "${arch}" 2>/dev/null || echo '')"
  elf_actual="$(smoke_elf_machine_of "${cc_bin}" 2>/dev/null || echo '')"
  if [ -n "${elf_expected}" ] && echo "${elf_actual}" | grep -qF "${elf_expected}"; then
    pass "cc ELF machine matches expected ${elf_expected}"
  elif [ -n "${elf_actual}" ]; then
    fail "cc ELF machine is ${elf_actual} (expected ${elf_expected})"
  fi
}

echo "=== Critical Fixes: in-image probes ==="
echo ""

IMAGE_FIX_FUNCS=(fix1_python_pc fix2_abseil_span fix3_libdynload_dangling fix4_cc_dumpmachine)
for _fix_fn in "${IMAGE_FIX_FUNCS[@]}"; do
  "${_fix_fn}"
  echo ""
done

smoke_summary
