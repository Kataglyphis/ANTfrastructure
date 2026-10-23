#!/usr/bin/env bash
set -euo pipefail

# Validates the pinned GCC/Clang for Dockerfile.package; mode: artifact-source | package | smoke.

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
# shellcheck source=media-payloads.sh
source "${_vcs_script_dir}/media-payloads.sh"
source_module platform.sh
source_module arch-mapping.sh
source_module common.sh   # alt_install_and_set (+ SUDO="" default)

validate_resolve_arch() {
  canonical_target_arch "${1:-${TARGET_ARCH:-}}"
}


# Validator probes report missing metadata through validate_fail rather than errexit.
_vc_clang_embedded_version() {
  clang_embedded_deb_version "$1" || true
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
    elif host_elf="$(LC_ALL=C readelf -h "${gcc_prefix}/bin/gcc" 2>/dev/null | grep 'Machine:' | head -1)"; then
      # A target-native GCC cannot run on the build host; check its ELF machine instead.
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
  # Under QEMU for a non-amd64 target, cross compilers are x86_64 binaries that cannot run.
  local cross_arches
  cross_arches="$(arch_list_csv_normalize "${CROSS_TARGETS:-amd64,arm64,riscv64}" 2>/dev/null || printf '%s' "${CROSS_TARGETS:-amd64,arm64,riscv64}")"
  local cross_arch triplet cross_gcc cross_ver
  # Callers may run under IFS=$'\n\t', where ${cross_arches//,/ } would not split.
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

_artifact_source_check_swapped_gcc() {
  local target_arch="$1" gcc_prefix="$2" native_gcc="$3"
  # Dockerfile.android's swap may already have moved the native GCC into /opt/gcc-${GCC_VERSION}.
  local main_gcc_dump main_gcc_elf expected_machine expected_triple
  main_gcc_dump="$("${gcc_prefix}/bin/gcc" -dumpmachine 2>/dev/null || true)"
  expected_machine="$(arch_to_elf_machine "${target_arch}" 2>/dev/null || true)"
  expected_triple=""
  if [ -n "${expected_machine}" ]; then
    expected_triple="$(arch_deb_multiarch_triplet_for "${target_arch}" 2>/dev/null || true)"
  fi
  if [ -n "${expected_triple}" ] && [ "${main_gcc_dump}" = "${expected_triple}" ]; then
    echo "OK: main gcc already reports target-native triple ${main_gcc_dump} (swap completed)"
  elif [ -n "${expected_machine}" ]; then
    main_gcc_elf="$(LC_ALL=C readelf -h "${gcc_prefix}/bin/gcc" 2>/dev/null | grep 'Machine:' | head -1 || true)"
    if echo "${main_gcc_elf}" | grep -qi "${expected_machine}"; then
      echo "OK: main gcc is cross-built ELF for ${target_arch} (${main_gcc_elf}) - swap completed"
    else
      validate_fail "native-gcc-missing" "expected target-native GCC at ${native_gcc}/bin/gcc for ${target_arch}"
    fi
  else
    validate_fail "native-gcc-missing" "expected target-native GCC at ${native_gcc}/bin/gcc for ${target_arch}"
  fi
}

_artifact_source_check_target_elf() {
  local binary="$1" label="$2" gate="$3" version_failure="$4" machine expected_machine
  machine="$(LC_ALL=C readelf -h "${binary}" 2>/dev/null | grep 'Machine:' | head -1 || true)"
  expected_machine="$(arch_to_elf_machine "${_VCS_TARGET_ARCH}" 2>/dev/null || true)"
  if [ -n "${expected_machine}" ] && echo "${machine}" | grep -qi "${expected_machine}"; then
    echo "OK: ${label} is cross-built ELF for ${_VCS_TARGET_ARCH} (${machine})"
  else
    validate_fail "${gate}" "${version_failure}${machine:+ ELF: ${machine}}"
  fi
}

_artifact_source_check_native_gcc() {
  local target_arch="${_VCS_TARGET_ARCH}"
  local gcc_prefix="${_VCS_GCC_PREFIX}"
  # target-native GCC
  if [ "${target_arch}" != "amd64" ]; then
    local native_gcc="/opt/gcc-${GCC_VERSION:-16.2.0}-native-${target_arch}"
    if [ -d "${native_gcc}" ] && [ -x "${native_gcc}/bin/gcc" ]; then
      local native_ver
      native_ver="$("${native_gcc}/bin/gcc" --version 2>/dev/null | head -1 || true)"
      if echo "${native_ver}" | grep -q "${GCC_VERSION:-16.2.0}"; then
        echo "OK: target-native ${native_gcc}/bin/gcc reports ${native_ver}"
      else
        _artifact_source_check_target_elf "${native_gcc}/bin/gcc" "target-native ${native_gcc}/bin/gcc" \
          native-gcc "${native_gcc}/bin/gcc --version: ${native_ver:-MISSING}"
      fi
    elif [ "${BUILD_MODE:-native}" = "cross" ]; then
      _artifact_source_check_swapped_gcc "${target_arch}" "${gcc_prefix}" "${native_gcc}"
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
    local clang_ver
    clang_ver="$(_vc_clang_embedded_version "${llvm_target}")"
    if printf '%s' "${clang_ver}" | grep -qxF "${LLVM_RELEASE:?LLVM_RELEASE must be set (versions.env)}"; then
      echo "OK: target clang ${llvm_target} reports ${clang_ver}"
    else
      # A cross-built clang cannot run here and has no DEB metadata, so check its ELF arch.
      _artifact_source_check_target_elf "${llvm_target}" "target clang ${llvm_target}" \
        target-clang "${llvm_target} --version: ${clang_ver:-MISSING} (expected ${LLVM_RELEASE:?LLVM_RELEASE must be set (versions.env)})"
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
  # Wire target-native LLVM alternatives through the canonical helper
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

  # Wire GCC alternatives
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

_cc_target_failure() {
  local gate="$1" message="$2" fatal_message="$3"
  if [ "${_VCS_CC_MODE}" = hard-fail ]; then
    echo "ERROR: ${fatal_message}" >&2
    exit 1
  fi
  validate_fail "${gate}" "${message}"
}

_cc_target_dumpmachine() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local mode="${_VCS_CC_MODE}"
  local cc_path="${_VCS_CC_PATH}"
  local expected_pattern="${_VCS_CC_EXPECTED_PATTERN}"
  local cc_dump
  # VALIDATE_CC_STATIC_ONLY=1 skips execution probes only; the readelf checks stay hard failures.
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
      _cc_target_failure cc-arch \
        "/usr/bin/cc (${cc_path}) dumpmachine '${cc_dump}' != expected ${expected_pattern} for ${target_arch}" \
        "/usr/bin/cc dumpmachine '${cc_dump}' does not match target arch ${target_arch}"
      return 0
    fi
    echo "Verified /usr/bin/cc target: ${cc_dump} (expected ${target_arch})"
  fi
}

_cc_target_elf_check() {
  local target_arch="${_VCS_CC_TARGET_ARCH}"
  local cc_path="${_VCS_CC_PATH}"
  local cc_pattern="${_VCS_CC_PATTERN}"
  local cc_machine cc_elf
  # swap-native-gcc.sh wraps foreign-arch cc in a shell script; readelf the .real binary instead.
  cc_elf="${cc_path}"
  [ -e "${cc_path}.real" ] && cc_elf="${cc_path}.real"
  if [ -n "${cc_pattern}" ] && command -v readelf >/dev/null 2>&1; then
    # || true: a non-ELF file would abort under set -e before the diagnostic below.
    cc_machine="$(elf_machine_name "${cc_elf}" || true)"
    if [ -z "${cc_machine}" ]; then
      _cc_target_failure cc-elf 'cannot read ELF machine of cc' "cannot read ELF machine type of cc (${cc_elf})"
      return 0
    fi
    case "${cc_machine}" in
      *"${cc_pattern}"*)
        echo "Verified /usr/bin/cc ELF machine: '${cc_machine}' matches ${target_arch}" ;;
      *)
        _cc_target_failure cc-elf "ELF machine '${cc_machine}' != '${cc_pattern}' for ${target_arch}" \
          "/usr/bin/cc (${cc_elf}) ELF machine '${cc_machine}' does not match '${cc_pattern}' for ${target_arch}"
        return 0
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

_cc_target_run_smoke() {
  local kind="$1" source="$2" name="$3" success="$4" failure="$5" gate="$6" message="$7"
  shift 7
  local directory output log
  directory="$(mktemp -d)"
  output="${directory}/${name}"
  log="${directory}/${name}.log"
  if printf '%s\n' "${source}" | cc -x c - "$@" -o "${output}" 2>"${log}"; then
    echo "Verified /usr/bin/cc ${success} for ${_VCS_CC_TARGET_ARCH}"
    if [ "${kind}" = compile ] && [ -n "${_VCS_CC_PATTERN}" ] && command -v readelf >/dev/null 2>&1; then
      _VCS_CC_COMPILE_TMPDIR="${directory}"
      _VCS_CC_OBJ="${output}"
      _cc_target_object_elf_check
    fi
  elif [ "${_VCS_CC_MODE}" = "hard-fail" ]; then
    echo "ERROR: ${failure}:" >&2
    cat "${log}" >&2 || true
    rm -rf "${directory}"
    exit 1
  else
    validate_fail "${gate}" "${message} for ${_VCS_CC_TARGET_ARCH}"
  fi
  rm -rf "${directory}"
}

_cc_target_compile_smoke() {
  _cc_target_run_smoke compile 'int answer(void){return 42;}' cc1smoke.o \
    'cc1 compile-to-object smoke' "cc1 compile-to-object smoke FAILED for ${_VCS_CC_TARGET_ARCH}" \
    cc1-smoke 'cc1 compile-to-object smoke failed' -c
}

_cc_target_link_smoke() {
  _cc_target_run_smoke link 'int main(void){return 0;}' cclinksmoke \
    'link smoke' "cc link smoke FAILED for ${_VCS_CC_TARGET_ARCH} (missing crt/startup files?)" \
    cc-link 'cc link smoke failed'
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
  # GCC version
  gcc_ver_out="$(gcc --version 2>/dev/null | head -1 || true)"
  if echo "${gcc_ver_out}" | grep -q "${gcc_ver}"; then
    echo "SMOKE OK: gcc reports ${gcc_ver_out}"
  else
    validate_fail "gcc-version" "gcc --version: ${gcc_ver_out:-MISSING} (expected ${gcc_ver})"
  fi

  # Clang version
  local _clang_real
  _clang_real="$(readlink -f "$(command -v clang 2>/dev/null)" 2>/dev/null || true)"
  clang_ver_out="$(_vc_clang_embedded_version "${_clang_real}")"
  if printf '%s' "${clang_ver_out}" | grep -qxF "${llvm_ver}"; then
    echo "SMOKE OK: clang reports ${clang_ver_out}"
  else
    validate_fail "clang-version" "clang --version: ${clang_ver_out:-MISSING} (expected ${llvm_ver})"
  fi
}

# Sampling remains advisory: stripped libraries may carry no compiler signature.
_smoke_compiler_signatures() {
  local compiler="$1" version="$2" depth cap pattern note libdir lib comment
  local -a names=()
  shift 2
  case "${compiler}" in
    GCC)
      depth=1; cap=5; pattern="GCC: (GNU) ${version}"
      names=(-name '*.so' -o -name '*.so.*')
      note='.comment signature found in sampled libs (may be clang-built or stripped)' ;;
    Clang)
      depth=2; cap=10; pattern="clang version ${version}"
      names=(-name '*.so' -o -name '*.a')
      note='.comment signature found (libraries may be GCC-built)' ;;
    *) return 1 ;;
  esac
  for libdir in "$@"; do
    [ -d "${libdir}" ] || continue
    while IFS= read -r lib; do
      [ -f "${lib}" ] || continue
      comment="$(readelf -p .comment "${lib}" 2>/dev/null || true)"
      if echo "${comment}" | grep -q "${pattern}"; then
        echo "SMOKE OK: ${lib} compiled with ${compiler} ${version}"
        return 0
      fi
    done < <(find "${libdir}" -maxdepth "${depth}" \( "${names[@]}" \) 2>/dev/null | head -"${cap}")
  done
  echo "SMOKE NOTE: no ${compiler} ${version} ${note}"
}

_smoke_gcc_signatures() {
  echo "=== smoke: checking compiled library compiler signatures ==="
  _smoke_compiler_signatures GCC "${_VCS_SMOKE_GCC_VER}" \
    /opt/opencv5/lib /opt/gstreamer/lib /opt/ffmpeg/lib /opt/libcamera/lib /usr/local/lib
}

_smoke_clang_signatures() {
  _smoke_compiler_signatures Clang "${_VCS_SMOKE_LLVM_VER}" /usr/local/llvm-target/lib /usr/local/lib
}

_smoke_symlink_chains() {
  local gcc_ver="${_VCS_SMOKE_GCC_VER}"
  # Symlink chains
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
  # Optional payloads note, never fail: they depend on the GPU variant and copy-media-payloads.sh sources.
  local payload observation
  while IFS='|' read -r payload observation; do
    [ "${observation}" = observe ] || continue
    if [ -e "${payload}" ]; then
      echo "SMOKE OK: payload ${payload}"
    else
      echo "SMOKE NOTE: optional payload missing: ${payload}"
    fi
  done < <(media_optional_payloads)
}

# sysconfig's OPT survives stripping; extension-module -O0 is not visible here.
_smoke_optimization_level() {
  local py_bin=""
  for _p in /opt/venv/bin/python3 /opt/python/.venv/bin/python3 /usr/local/bin/python3; do
    [ -x "${_p}" ] && py_bin="${_p}" && break
  done
  if [ -z "${py_bin}" ]; then
    echo "SMOKE NOTE: no python3 found for -O assertion"
    return 0
  fi
  local opt_str
  opt_str="$("${py_bin}" -c 'import sysconfig; print(sysconfig.get_config_var("OPT") or "")' 2>/dev/null || true)"
  if [ -z "${opt_str}" ]; then
    echo "SMOKE NOTE: could not read CPython OPT from sysconfig"
    return 0
  fi
  if echo "${opt_str}" | grep -q -- '-O0'; then
    validate_fail "opt-level" "CPython OPT contains -O0 (unoptimized): ${opt_str}"
  elif ! echo "${opt_str}" | grep -q -- '-O[1-3]'; then
    validate_fail "opt-level" "CPython OPT has no -O flag at all: ${opt_str}"
  else
    echo "SMOKE OK: CPython OPT = ${opt_str}"
  fi
}

# Compile+link only; smoke-runtime-image.sh runs it natively. docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer
_smoke_gcc_sanitizers() {
  local d dyn=""; d="$(mktemp -d)"
  # (8 >> c): a variable shift exponent keeps a UBSan call under GCC 16's C++20 default.
  printf '#include <sanitizer/common_interface_defs.h>\nalignas(8) static char b[8];\nint main(int c, char **) {\n  __sanitizer_annotate_contiguous_container(b, b + 8, b + 8, b + 8);\n  return (8 >> c) == 4 ? 0 : 1;\n}\n' > "${d}/s.cpp"
  if g++ -O1 -fsanitize=address,undefined "${d}/s.cpp" -o "${d}/s" 2>"${d}/e"; then
    dyn="$(readelf -d "${d}/s" 2>/dev/null || true)"
  fi
  if grep -q 'NEEDED.*libasan\.so' <<<"${dyn}" && grep -q 'NEEDED.*libubsan\.so' <<<"${dyn}"; then
    echo "SMOKE OK: g++ -fsanitize=address,undefined compiles+links (libasan+libubsan NEEDED)"
  else
    sed 's/^/    /' "${d}/e" >&2 || true
    validate_fail "gcc-sanitizers" "g++ -fsanitize=address,undefined failed or did not link libasan/libubsan"
  fi
  rm -rf "${d}"
}

# A bare clang++, and clang-tidy through the /usr/bin link, find the image's GCC via setup-package-image.sh's clang config file.
_smoke_clang_gcc_toolchain() {
  local sel d cc
  sel="$(clang++ -x c++ -v -fsyntax-only /dev/null 2>&1 | sed -n 's/^Selected GCC installation: //p')"
  _smoke_gcc_selection "bare clang++" "${sel}"
  d="$(mktemp -d)"
  : > "${d}/t.cpp"
  for cc in /usr/bin/clang /usr/bin/clang++; do
    printf '[{"directory":"%s","file":"t.cpp","command":"%s -c t.cpp -o t.o"}]\n' "${d}" "${cc}" > "${d}/compile_commands.json"
    sel="$(clang-tidy -p "${d}" --checks=-*,misc-definitions-in-headers --extra-arg=-v "${d}/t.cpp" 2>&1 \
      | sed -n 's/^Selected GCC installation: //p' || true)"
    _smoke_gcc_selection "clang-tidy via ${cc}" "${sel}"
  done
  rm -rf "${d}"
}

_smoke_gcc_selection() {
  case "$2" in
    "${GCC_PREFIX:?GCC_PREFIX must be set}"/*) echo "SMOKE OK: $1 selects $2" ;;
    *) validate_fail "clang-gcc-toolchain" "$1 selects '${2:-no GCC}', not ${GCC_PREFIX}" ;;
  esac
}

# The ones with a --version; lldb and the utilities are built into the pinned LLVM for this (BACKLOG CON71).
_SMOKE_LLVM_TOOLS="clang clang++ clang-cl clang-cpp clang-tidy clang-apply-replacements clang-format clangd
  clang-scan-deps llvm-config llvm-profdata llvm-cov llvm-symbolizer llvm-ar llvm-nm llvm-objdump llvm-objcopy
  llvm-readelf ld.lld opt llc lldb FileCheck yaml2obj llvm-tblgen"

# Every LLVM tool a consumer names unversioned is LLVM_RELEASE's (wire_pinned_llvm_tools, BACKLOG CON71).
_smoke_llvm_tool_versions() {
  local want="${_VCS_SMOKE_LLVM_VER:-${LLVM_RELEASE:-}}" usr_bin="${1:-/usr/bin}" tool ver name
  for tool in ${_SMOKE_LLVM_TOOLS}; do
    ver="$("${tool}" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [ -n "${want}" ] && [ "${ver}" = "${want}" ]; then
      echo "SMOKE OK: ${tool} ${ver} == LLVM_RELEASE"
    else
      validate_fail "llvm-tool-version" "${tool} ${ver:-MISSING} is not LLVM_RELEASE ${want:-MISSING}"
    fi
  done
  # The package stage ships the wiring beside this script; one predicate decides what the wiring diverts and what fails here.
  declare -F llvm_distro_unversioned_names >/dev/null || source "${_vcs_script_dir}/package-image-wiring.sh"
  while IFS= read -r name; do
    validate_fail "llvm-tool-distro" "${usr_bin}/${name} is $(readlink -f "${usr_bin}/${name}"), a distro LLVM under an unversioned name"
  done < <(llvm_distro_unversioned_names "${usr_bin}")
}

# clang ships libFuzzer (llvm-cross.sh, BACKLOG CON17): a fuzz target links and runs.
_smoke_clang_libfuzzer() {
  local d
  d="$(mktemp -d)"
  printf 'int LLVMFuzzerTestOneInput(const unsigned char *d, unsigned long n) { (void)d; (void)n; return 0; }\n' > "${d}/f.c"
  if clang -fsanitize=fuzzer "${d}/f.c" -o "${d}/f" 2>"${d}/e" && "${d}/f" -runs=10 >/dev/null 2>&1; then
    echo "SMOKE OK: clang -fsanitize=fuzzer links and runs"
  else
    sed 's/^/    /' "${d}/e" >&2 || true
    validate_fail "clang-libfuzzer" "clang -fsanitize=fuzzer failed to link or run a trivial target"
  fi
  rm -rf "${d}"
}

# Ports atheris' own find_libfuzzer.sh probe, which walks -print-search-dirs for the legacy lib/linux names (CON38).
_smoke_atheris_libfuzzer_probe() {
  local machine lib dir found="" rt
  local -a dirs=()
  machine="$(uname -m)"
  case "${machine}" in
    x86_64 | aarch64) lib="lib/linux/libclang_rt.fuzzer_no_main-${machine}.a" ;;
    *) echo "SMOKE NOTE: atheris' probe knows no ${machine}; atheris needs LIBFUZZER_LIB there"; return 0 ;;
  esac
  IFS=':' read -r -a dirs <<< "$(clang -print-search-dirs 2>/dev/null | sed -n 's/^libraries: =//p')"
  for dir in "${dirs[@]}"; do
    if [ -f "${dir}/${lib}" ]; then found="${dir}/${lib}"; break; fi
  done
  if [ -z "${found}" ]; then
    validate_fail "atheris-libfuzzer" "atheris' probe finds no ${lib} under clang's library dirs"
    return 0
  fi
  # setup.py merges the sanitizers named after the same path, and needs LLVMFuzzerRunDriver.
  for rt in asan ubsan_standalone ubsan_standalone_cxx; do
    [ -f "${found/.fuzzer_no_main/.${rt}}" ] || validate_fail "atheris-libfuzzer" "no ${found/.fuzzer_no_main/.${rt}} beside ${found}"
  done
  if objdump -t "${found}" 2>/dev/null | grep LLVMFuzzerRunDriver >/dev/null; then
    echo "SMOKE OK: atheris' probe finds ${found}"
  else
    validate_fail "atheris-libfuzzer" "${found} has no LLVMFuzzerRunDriver (atheris calls it outdated)"
  fi
}

validate_smoke() {
  local gcc_ver="${GCC_VERSION:-16.2.0}"
  local llvm_ver="${LLVM_RELEASE:?LLVM_RELEASE must be set (versions.env)}"
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
  _smoke_optimization_level
  _smoke_gcc_sanitizers
  _smoke_clang_gcc_toolchain
  _smoke_llvm_tool_versions
  _smoke_clang_libfuzzer
  _smoke_atheris_libfuzzer_probe

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