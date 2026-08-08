#!/usr/bin/env bash
set -euo pipefail

# validate-compilers.sh
# Unified compiler chain validation for the pinned GCC (versions.env GCC_VERSION) and Clang 22.1.8.
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
for _vcs_mod_path in \
  "/opt/scripts/core/modules.sh" \
  "${_vcs_script_dir}/../01-core/modules.sh"; do
  if [ -f "${_vcs_mod_path}" ]; then
    # shellcheck disable=SC1090
    source "${_vcs_mod_path}"
    break
  fi
done
source_module platform.sh
source_module arch-mapping.sh
source_module common.sh   # alt_install_and_set (+ SUDO="" default)

validate_resolve_arch() {
  canonical_target_arch "${1:-${TARGET_ARCH:-}}"
}


# Read a clang binary's version from its embedded DEB package metadata
# (avoids the runtime-lib resolution issue where apt's libclang-cpp shadows
# the source-built one), with a --version regex fallback for binaries without
# the metadata. Complexity audit F-B: this file carried TWO drifted inline
# copies of the strings-pipeline; the copy without the fallback turned an
# empty `strings` result into a false "version MISSING" failure.
_vc_clang_embedded_version() {
  local _bin="$1" _ver
  _ver="$( strings "${_bin}" 2>/dev/null \
      | grep -o '"version":"[^"]*"' \
      | head -1 | tr -d \" | cut -d: -f3 | cut -d~ -f1 || true )"
  if [ -z "${_ver}" ]; then
    _ver="$( "${_bin}" --version 2>/dev/null \
        | grep -oiE 'clang version [0-9]+\.[0-9]+\.[0-9]+' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true )"
  fi
  printf '%s' "${_ver}"
}

validate_fail() {
  echo "COMPILER FAIL [$1]: $2" >&2
  _VALIDATE_ERRORS=$((_VALIDATE_ERRORS + 1))
}

_artifact_source_check_host_gcc() {
  local target_arch="${_VCS_TARGET_ARCH}"
  local gcc_prefix="${_VCS_GCC_PREFIX}"
  # host GCC
  if [ -x "${gcc_prefix}/bin/gcc" ]; then
    local host_ver host_elf
    host_ver="$("${gcc_prefix}/bin/gcc" --version 2>/dev/null | head -1 || true)"
    if echo "${host_ver}" | grep -q "${GCC_VERSION:-16.2.0}"; then
      echo "OK: host gcc ${gcc_prefix}/bin/gcc reports ${host_ver}"
    elif host_elf="$(readelf -h "${gcc_prefix}/bin/gcc" 2>/dev/null | grep 'Machine:' | head -1)"; then
      # Cross-built GCC binary (target-native) can't execute on build host.
      # Accept if the ELF machine matches the target arch.
      local expected_machine=""
      expected_machine="$(arch_to_elf_machine "${target_arch}" 2>/dev/null || true)"
      if echo "${host_elf}" | grep -qi "${expected_machine}"; then
        echo "OK: host gcc ${gcc_prefix}/bin/gcc is cross-built ELF for ${target_arch} (${host_elf})"
      else
        validate_fail "host-gcc" "${gcc_prefix}/bin/gcc --version: ${host_ver:-MISSING} (expected ${GCC_VERSION:-16.2.0}), ELF: ${host_elf}"
      fi
    else
      validate_fail "host-gcc" "${gcc_prefix}/bin/gcc --version: ${host_ver:-MISSING} (expected ${GCC_VERSION:-16.2.0})"
    fi
  else
    validate_fail "host-gcc-missing" "${gcc_prefix}/bin/gcc not found"
  fi
}

_artifact_source_check_cross_compilers() {
  local target_arch="${_VCS_TARGET_ARCH}"
  local gcc_prefix="${_VCS_GCC_PREFIX}"
  # cross compilers — derive list from CROSS_TARGETS or platform default
  # Under QEMU emulation for a non-amd64 target, cross compilers for other
  # arches are x86_64 host binaries that cannot execute; skip --version checks.
  local cross_arches
  cross_arches="$(arch_list_csv_normalize "${CROSS_TARGETS:-amd64,arm64,riscv64}" 2>/dev/null || printf '%s' "${CROSS_TARGETS:-amd64,arm64,riscv64}")"
  local cross_arch triplet cross_gcc cross_ver
  # Split on commas via `IFS=',' read` (scoped to the builtin): callers may run
  # under IFS=$'\n\t', where ${cross_arches//,/ } does not split on spaces.
  local -a _vcs_arches=()
  IFS=',' read -r -a _vcs_arches <<< "${cross_arches}"
  for cross_arch in "${_vcs_arches[@]}"; do
    [ "${cross_arch}" = "${target_arch}" ] && continue
    triplet="$(arch_deb_multiarch_triplet_for "${cross_arch}" 2>/dev/null || true)"
    [ -n "${triplet}" ] || continue
    cross_gcc="${gcc_prefix}/bin/${triplet}-gcc"
    if [ -x "${cross_gcc}" ]; then
      if [ "${target_arch}" = "amd64" ]; then
        cross_ver="$("${cross_gcc}" --version 2>/dev/null | head -1 || true)"
        if echo "${cross_ver}" | grep -q "${GCC_VERSION:-16.2.0}"; then
          echo "OK: cross ${cross_gcc} reports ${cross_ver}"
        else
          validate_fail "cross-gcc-${cross_arch}" "${cross_gcc} --version: ${cross_ver:-MISSING}"
        fi
      else
        echo "OK: cross ${cross_gcc} present (skipping --version under QEMU emulation for ${target_arch})"
      fi
    fi
  done
}

_artifact_source_check_native_gcc() {
  local target_arch="${_VCS_TARGET_ARCH}"
  local gcc_prefix="${_VCS_GCC_PREFIX}"
  # target-native GCC
  if [ "${target_arch}" != "amd64" ]; then
    local native_gcc="/opt/gcc-${GCC_VERSION:-16.2.0}-native-${target_arch}"
    if [ -d "${native_gcc}" ] && [ -x "${native_gcc}/bin/gcc" ]; then
      local native_ver native_elf expected_machine
      native_ver="$("${native_gcc}/bin/gcc" --version 2>/dev/null | head -1 || true)"
      if echo "${native_ver}" | grep -q "${GCC_VERSION:-16.2.0}"; then
        echo "OK: target-native ${native_gcc}/bin/gcc reports ${native_ver}"
      else
        native_elf="$(readelf -h "${native_gcc}/bin/gcc" 2>/dev/null | grep 'Machine:' | head -1 || true)"
        expected_machine="$(arch_to_elf_machine "${target_arch}" 2>/dev/null || true)"
        if [ -n "${expected_machine}" ] && echo "${native_elf}" | grep -qi "${expected_machine}"; then
          echo "OK: target-native ${native_gcc}/bin/gcc is cross-built ELF for ${target_arch} (${native_elf})"
        else
          validate_fail "native-gcc" "${native_gcc}/bin/gcc --version: ${native_ver:-MISSING}${native_elf:+ ELF: ${native_elf}}"
        fi
      fi
    elif [ "${BUILD_MODE:-native}" = "cross" ]; then
      # The GCC swap in Dockerfile.android may have already moved the
      # native GCC into /opt/gcc-${GCC_VERSION}.  If the main GCC
      # already reports the correct architecture (via -dumpmachine or
      # readelf), the swap succeeded.
      local main_gcc_dump main_gcc_elf
      main_gcc_dump="$("${gcc_prefix}/bin/gcc" -dumpmachine 2>/dev/null || true)"
      expected_machine="$(arch_to_elf_machine "${target_arch}" 2>/dev/null || true)"
      expected_triple=""
      if [ -n "${expected_machine}" ]; then
        expected_triple="$(arch_deb_multiarch_triplet_for "${target_arch}" 2>/dev/null || true)"
      fi
      if [ -n "${expected_triple}" ] && [ "${main_gcc_dump}" = "${expected_triple}" ]; then
        echo "OK: main gcc already reports target-native triple ${main_gcc_dump} (swap completed)"
      elif [ -n "${expected_machine}" ]; then
        main_gcc_elf="$(readelf -h "${gcc_prefix}/bin/gcc" 2>/dev/null | grep 'Machine:' | head -1 || true)"
        if echo "${main_gcc_elf}" | grep -qi "${expected_machine}"; then
          echo "OK: main gcc is cross-built ELF for ${target_arch} (${main_gcc_elf}) - swap completed"
        else
          validate_fail "native-gcc-missing" "expected target-native GCC at ${native_gcc}/bin/gcc for ${target_arch}"
        fi
      else
        validate_fail "native-gcc-missing" "expected target-native GCC at ${native_gcc}/bin/gcc for ${target_arch}"
      fi
    fi
  fi
}

_artifact_source_check_llvm() {
  local target_arch="${_VCS_TARGET_ARCH}"
  local llvm_target
  # target-native Clang
  llvm_target="/opt/llvm-target/bin/clang"
  if [ ! -e /opt/llvm-target ]; then
    if [ "${target_arch}" = "amd64" ]; then
      echo "WARNING: /opt/llvm-target not found for amd64; continuing with distro LLVM"
    else
      validate_fail "llvm-target-missing" "/opt/llvm-target symlink/directory not found (should be created by setup step)"
    fi
  fi
  if [ -x "${llvm_target}" ]; then
    local clang_ver clang_major_minor
    # Read version from binary's embedded DEB metadata (avoids runtime lib
    # resolution issue where apt's libclang-cpp shadows the source-built one).
    clang_ver="$(_vc_clang_embedded_version "${llvm_target}")"
    if echo "${clang_ver}" | grep -q "${LLVM_RELEASE:-22.1.8}"; then
      echo "OK: target clang ${llvm_target} reports ${clang_ver}"
    else
      clang_major_minor="${LLVM_RELEASE:-22.1.8}"
      clang_major_minor="${clang_major_minor%.*}"
      if [[ "${clang_ver}" == *"clang version ${clang_major_minor}"* ]]; then
        echo "OK: target clang ${llvm_target} reports ${clang_ver} (major.minor ${clang_major_minor} matches)"
      else
        # Cross-built Clang can't execute on build host; check ELF arch instead
        local clang_elf
        clang_elf="$(readelf -h "${llvm_target}" 2>/dev/null | grep 'Machine:' | head -1 || true)"
        local expected_machine=""
        expected_machine="$(arch_to_elf_machine "${target_arch}" 2>/dev/null || true)"
        if [ -n "${expected_machine}" ] && echo "${clang_elf}" | grep -qi "${expected_machine}"; then
          echo "OK: target clang ${llvm_target} is cross-built ELF for ${target_arch} (${clang_elf})"
        else
          validate_fail "target-clang" "${llvm_target} --version: ${clang_ver:-MISSING} (expected ${LLVM_RELEASE:-22.1.8})${clang_elf:+ ELF: ${clang_elf}}"
        fi
      fi
    fi
  elif cross_build_is_active && [ -d /opt/llvm-target ]; then
    validate_fail "target-clang-missing" "${llvm_target} not executable in /opt/llvm-target"
  else
    echo "WARNING: missing target-native LLVM toolchain for ${target_arch}; continuing with distro LLVM"
  fi
}

validate_artifact_source() {
  local gcc_prefix
  _VCS_TARGET_ARCH="$(validate_resolve_arch)"
  echo "=== artifact-source: verifying compilers for target_arch=${_VCS_TARGET_ARCH} ==="
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.2.0}"
  _VCS_GCC_PREFIX="${gcc_prefix}"
  _VALIDATE_ERRORS=0

  _artifact_source_check_host_gcc
  _artifact_source_check_cross_compilers
  _artifact_source_check_native_gcc
  _artifact_source_check_llvm

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "ARTIFACT COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
  echo "ARTIFACT COMPILER VERIFICATION PASSED for ${_VCS_TARGET_ARCH}"
}

validate_package() {
  local target_arch gcc_prefix
  target_arch="$(validate_resolve_arch)"
  _VALIDATE_ERRORS=0

  local tool candidate
  # --- wire target-native LLVM alternatives (install+set via canonical helper) ---
  if [ -d /usr/local/llvm-target ]; then
    for tool in clang clang++ llvm-ar llvm-ranlib; do
      candidate="/usr/local/llvm-target/bin/${tool}"
      if [ -x "${candidate}" ]; then
        alt_install_and_set "${tool}" "/usr/bin/${tool}" "${candidate}" 120
      else
        echo "WARNING: expected target-native LLVM tool missing: ${candidate}" >&2
      fi
    done
  else
    echo "WARNING: /usr/local/llvm-target not found; using distro LLVM"
  fi

  # --- wire GCC alternatives ---
  gcc_prefix="/opt/gcc-${GCC_VERSION:-16.2.0}"
  if [ -d "${gcc_prefix}" ]; then
    for tool in gcc g++ gcov; do
      candidate="${gcc_prefix}/bin/${tool}"
      [ -x "${candidate}" ] && alt_install_and_set "${tool}" "/usr/bin/${tool}" "${candidate}" 150
    done
    [ -x "${gcc_prefix}/bin/gcc" ] && alt_install_and_set cc  /usr/bin/cc  "${gcc_prefix}/bin/gcc" 150
    [ -x "${gcc_prefix}/bin/g++" ] && alt_install_and_set c++ /usr/bin/c++ "${gcc_prefix}/bin/g++" 150
  else
    echo "WARNING: Custom GCC prefix ${gcc_prefix} not found"
  fi

  _validate_cc_target "${target_arch}" hard-fail

  if [ "${_VALIDATE_ERRORS}" -gt 0 ]; then
    echo "PACKAGE COMPILER VERIFICATION FAILED: ${_VALIDATE_ERRORS} check(s)" >&2
    exit 1
  fi
}

_cc_target_dumpmachine() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_path="${_VCS_CC_PATH}"
  local expected_pattern="${_VCS_CC_EXPECTED_PATTERN}"
  local cc_dump
  # VALIDATE_CC_STATIC_ONLY=1: cc is a TARGET-native ELF that cannot execute
  # on the build host (cross package images). Execution probes (-dumpmachine,
  # cc1, link) are skipped with a note; the readelf static checks below remain
  # HARD — so alternatives mis-wiring still fails the build instead of being
  # downgraded to a warning by the caller.
  cc_dump="$(cc -dumpmachine 2>/dev/null || true)"
  if [ -z "${cc_dump}" ]; then
    if [ "${VALIDATE_CC_STATIC_ONLY:-0}" = "1" ]; then
      echo "NOTE: 'cc -dumpmachine' skipped (target-native binary, not executable on build host); relying on ELF checks"
    elif [ "${mode}" = "hard-fail" ]; then
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
}

_cc_target_elf_check() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_path="${_VCS_CC_PATH}"
  local cc_pattern="${_VCS_CC_PATTERN}"
  local cc_machine cc_elf
  # swap-native-gcc.sh replaces the foreign-arch gcc/cc on disk with a
  # `#!/bin/sh` wrapper (it execs `<cc>.real` with -idirafter injected to fix the
  # runtime image's system headers). readelf cannot inspect a shell script, so
  # point the ELF machine-type check at the underlying real binary when a
  # `.real` sibling exists. Unwrapped compilers (amd64) have no `.real` and are
  # inspected directly, exactly as before.
  cc_elf="${cc_path}"
  [ -e "${cc_path}.real" ] && cc_elf="${cc_path}.real"
  if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
    # `|| true`: elf_machine_name returns non-zero (under the caller's pipefail)
    # when handed a non-ELF file; tolerate it so the empty-result branch below
    # emits a real diagnostic instead of a silent `set -e` abort.
    cc_machine="$(elf_machine_name "${cc_elf}" || true)"
    if [ -z "${cc_machine}" ]; then
      if [ "${mode}" = "hard-fail" ]; then
        echo "ERROR: cannot read ELF machine type of cc (${cc_elf})" >&2
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
          echo "ERROR: /usr/bin/cc (${cc_elf}) ELF machine '${cc_machine}' does not match '${cc_pattern}' for ${target_arch}" >&2
          exit 1
        else
          validate_fail "cc-elf" "ELF machine '${cc_machine}' != '${cc_pattern}' for ${target_arch}"
          return 0
        fi
        ;;
    esac
  fi
}

_cc_target_object_elf_check() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_pattern="${_VCS_CC_PATTERN}"
  local cc_obj="${_VCS_CC_OBJ}"
  local obj_machine
  obj_machine="$(elf_machine_name "${cc_obj}")"
  case "${obj_machine}" in
    *"${cc_pattern}"*) echo "Verified cc1 output object ELF machine '${obj_machine}' matches ${target_arch}" ;;
    *)
      if [ "${mode}" = "hard-fail" ]; then
        echo "ERROR: cc1 produced object with ELF machine '${obj_machine}', expected '${cc_pattern}' for ${target_arch}" >&2; rm -rf "${_VCS_CC_COMPILE_TMPDIR}"; exit 1
      else
        validate_fail "cc1-obj-elf" "object ELF machine '${obj_machine}' != '${cc_pattern}'"
      fi
      ;;
  esac
}

_cc_target_compile_smoke() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_pattern="${_VCS_CC_PATTERN}"
  local cc_obj _cc1_tmpdir
  _cc1_tmpdir="$(mktemp -d)"
  _VCS_CC_COMPILE_TMPDIR="${_cc1_tmpdir}"
  cc_obj="${_cc1_tmpdir}/cc1smoke.o"
  _VCS_CC_OBJ="${cc_obj}"
  local _cc1_log="${_cc1_tmpdir}/cc1smoke.log"
  if printf 'int answer(void){return 42;}\n' | cc -x c - -c -o "${cc_obj}" 2>"${_cc1_log}"; then
    echo "Verified /usr/bin/cc cc1 compile-to-object smoke for ${target_arch}"
    if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
      _cc_target_object_elf_check
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
}

_cc_target_link_smoke() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_exe _cc_link_tmpdir
  _cc_link_tmpdir="$(mktemp -d)"
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

_validate_cc_target() {
  local target_arch="$1"
  local mode="${2:-smoke}"
  local cc_path expected_pattern cc_pattern

  cc_path="$(update-alternatives --query cc 2>/dev/null | grep '^Value:' | cut -d' ' -f2 || true)"
  [ -z "${cc_path}" ] && cc_path="$(command -v cc 2>/dev/null || true)"
  _VCS_CC_PATH="${cc_path}"

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
  _VCS_CC_TARGET_ARCH="${target_arch}"
  _VCS_CC_MODE="${mode}"
  _VCS_CC_EXPECTED_PATTERN="${expected_pattern}"
  _VCS_CC_PATTERN="${cc_pattern}"

  _cc_target_dumpmachine
  _cc_target_elf_check

  if [ "${VALIDATE_CC_STATIC_ONLY:-0}" = "1" ]; then
    echo "NOTE: cc1/link execution smokes skipped (VALIDATE_CC_STATIC_ONLY=1); ELF checks above are authoritative"
    return 0
  fi

  _cc_target_compile_smoke
  _cc_target_link_smoke
}

_smoke_compiler_versions() {
  local gcc_ver="${_VCS_SMOKE_GCC_VER}"
  local llvm_ver="${_VCS_SMOKE_LLVM_VER}"
  local gcc_ver_out clang_ver_out
  # --- gcc version ---
  gcc_ver_out="$(gcc --version 2>/dev/null | head -1 || true)"
  if echo "${gcc_ver_out}" | grep -q "${gcc_ver}"; then
    echo "SMOKE OK: gcc reports ${gcc_ver_out}"
  else
    validate_fail "gcc-version" "gcc --version: ${gcc_ver_out:-MISSING} (expected ${gcc_ver})"
  fi

  # --- clang version ---
  _clang_real="$(readlink -f "$(command -v clang)" 2>/dev/null)"
  clang_ver_out="$(_vc_clang_embedded_version "${_clang_real}")"
  if echo "${clang_ver_out}" | grep -q "${llvm_ver}"; then
    echo "SMOKE OK: clang reports ${clang_ver_out}"
  else
    validate_fail "clang-version" "clang --version: ${clang_ver_out:-MISSING} (expected ${llvm_ver})"
  fi
}

_smoke_gcc_signatures() {
  local gcc_ver="${_VCS_SMOKE_GCC_VER}"
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
}

_smoke_clang_signatures() {
  local llvm_ver="${_VCS_SMOKE_LLVM_VER}"
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
}

_smoke_symlink_chains() {
  local gcc_ver="${_VCS_SMOKE_GCC_VER}"
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
}

_smoke_optional_payloads() {
  # --- optional runtime payloads ---
  # These are genuinely OPTIONAL (the comment always said so): onnxruntime-gpu
  # exists only on GPU variants, and the rest depend on copy-media-payloads.sh
  # having sources in the artifact image. Missing => NOTE, not failure — the
  # old validate_fail here failed every package build while the payload copy
  # script was orphaned.
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
      echo "SMOKE NOTE: optional payload missing: ${payload}"
    fi
  done
}

validate_smoke() {
  local gcc_ver="${GCC_VERSION:-16.2.0}"
  local llvm_ver="${LLVM_RELEASE:-22.1.8}"
  local target_arch

  target_arch="$(validate_resolve_arch)"
  _VCS_SMOKE_GCC_VER="${gcc_ver}"
  _VCS_SMOKE_LLVM_VER="${llvm_ver}"
  echo "=== smoke: target_arch=${target_arch} ==="
  _VALIDATE_ERRORS=0

  _validate_cc_target "${target_arch}" smoke

  _smoke_compiler_versions
  _smoke_gcc_signatures
  _smoke_clang_signatures
  _smoke_symlink_chains
  _smoke_optional_payloads

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