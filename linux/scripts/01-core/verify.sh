#!/usr/bin/env bash
# verify.sh - print versions

# Read a `--version`-style stream on stdin and print the first whitespace-
# separated token on line 1 that looks like a dotted version number
# (e.g. "1.2" or "20.1.8"). Used to extract clang/generic tool versions.
_first_version_token() {
  awk 'NR==1 {for (i = 1; i <= NF; ++i) if ($i ~ /^[0-9]+(\.[0-9]+)+$/) {print $i; exit}}'
}

verify_tool_with_path() {
  local tool="$1"
  shift || true

  if command -v "$tool" >/dev/null 2>&1; then
    log "${tool} -> $(command -v "$tool")"
    "$tool" "$@"
  fi
}

verify_required_tool() {
  local tool="$1"

  command -v "$tool" >/dev/null 2>&1 || die "Required tool is missing: ${tool}"
  log "${tool} -> $(command -v "$tool")"
}

verify_tool_major_version() {
  local tool="$1"
  local requested_major="$2"
  local raw_version=""
  local actual_major=""

  [ -n "${requested_major}" ] || return 0
  verify_required_tool "${tool}"

  case "${tool}" in
    gcc|g++|*-gcc|*-g++)
      raw_version="$(${tool} -dumpfullversion -dumpversion 2>/dev/null || true)"
      ;;
    llvm-config|llvm-config-*)
      raw_version="$(${tool} --version 2>/dev/null || true)"
      ;;
    *)
      # clang/clang++ (and any other tool) fall through here: extract the first
      # dotted version token from line 1 of `--version`.
      raw_version="$(${tool} --version 2>/dev/null | _first_version_token || true)"
      ;;
  esac

  raw_version="${raw_version%%[[:space:]]*}"
  [ -n "${raw_version}" ] || die "Could not determine version for ${tool}"
  actual_major="$(version_major "${raw_version}" 2>/dev/null || true)"
  [ -n "${actual_major}" ] || die "Could not determine major version for ${tool} from '${raw_version}'"
  [ "${actual_major}" = "${requested_major}" ] || \
    die "${tool} major version mismatch: expected ${requested_major}, got ${raw_version}"
}

verify_lld_version() {
  if command -v ld.lld >/dev/null 2>&1; then
    verify_tool_with_path ld.lld --version
  else
    verify_tool_with_path lld -flavor gnu --version
  fi
}

verify_cross_mode_requested() {
  if declare -F cross_mode_requested >/dev/null 2>&1; then
    cross_mode_requested
    return $?
  fi

  [ "${BUILD_MODE:-native}" = "cross" ]
}

verify_cross_target_versions() {
  local target_arch
  target_arch="$(default_target_arch)"
  local triplet=""
  local clang_target=""
  local requested_major="$(version_major "${GCC_WANTED}")"
  local requested_llvm_major="$(version_major "${LLVM_WANTED:-${CLANG_WANTED:-}}" 2>/dev/null || true)"

  target_arch="$(arch_normalize "${target_arch}")"
  case "${target_arch}" in
    amd64|arm64|riscv64) ;;
    *) return 0 ;;
  esac

  triplet="$(arch_deb_multiarch_triplet_for "${target_arch}")" || return 0
  clang_target="${target_arch}"

  log "Target cross toolchain for ARCH=${target_arch}:"
  verify_required_tool "${triplet}-gcc"
  verify_required_tool "${triplet}-g++"
  verify_required_tool "${triplet}-ar"
  verify_tool_with_path "${triplet}-gcc" --version
  verify_tool_with_path "${triplet}-g++" --version
  verify_tool_with_path "${triplet}-ar" --version
  verify_tool_major_version "${triplet}-g++" "${requested_major}"
  if [ -n "${LIBRARY_PATH:-}" ]; then
    log "Cross LIBRARY_PATH=${LIBRARY_PATH}"
  fi
  verify_required_tool "clang-${clang_target}"
  verify_required_tool "clang++-${clang_target}"
  verify_tool_with_path "clang-${clang_target}" --version
  verify_tool_with_path "clang++-${clang_target}" --version
  verify_tool_major_version "clang-${clang_target}" "${requested_llvm_major}"
  verify_tool_major_version "clang++-${clang_target}" "${requested_llvm_major}"
}

verify_all_cross_target_versions() {
  local targets_raw=""
  local target=""
  local old_arch="${ARCH:-}"
  local old_targetarch="${TARGETARCH:-}"
  local old_target_arch="${TARGET_ARCH:-}"

  verify_cross_mode_requested || return 0

  if declare -F cross_effective_targets_raw >/dev/null 2>&1; then
    targets_raw="$(cross_effective_targets_raw)"
  else
    targets_raw="${VERIFY_CROSS_TARGETS:-${CROSS_TARGETS:-${ARCH:-${TARGETARCH:-${TARGET_ARCH:-}}}}}"
  fi
  [ -n "${targets_raw}" ] || return 0
  targets_raw="$(arch_list_csv_normalize "${targets_raw}")" || return 0

  for target in ${targets_raw//,/ }; do
    ARCH="${target}"
    TARGETARCH="${target}"
    TARGET_ARCH="${target}"
    export ARCH TARGETARCH TARGET_ARCH
    verify_cross_target_versions
  done

  if [ -n "${old_arch}" ]; then
    ARCH="${old_arch}"
  else
    unset ARCH
  fi
  if [ -n "${old_targetarch}" ]; then
    TARGETARCH="${old_targetarch}"
  else
    unset TARGETARCH
  fi
  if [ -n "${old_target_arch}" ]; then
    TARGET_ARCH="${old_target_arch}"
  else
    unset TARGET_ARCH
  fi
}

verify_host_toolchain_versions() {
  local requested_gcc_major="$(version_major "${GCC_WANTED}" 2>/dev/null || true)"
  local requested_llvm_major="$(version_major "${LLVM_WANTED:-${CLANG_WANTED:-}}" 2>/dev/null || true)"

  verify_required_tool gcc
  verify_required_tool g++
  verify_required_tool clang
  verify_required_tool llvm-config

  verify_tool_major_version gcc "${requested_gcc_major}"
  verify_tool_major_version g++ "${requested_gcc_major}"
  verify_tool_major_version clang "${requested_llvm_major}"
  verify_tool_major_version llvm-config "${requested_llvm_major}"
}

verify_summary() {
  log "Installed versions:"
  tool_version cmake --version
  tool_version ccache --version

  if verify_cross_mode_requested; then
    log "Host toolchain on the builder image:"
  fi
  verify_host_toolchain_versions
  for t in gcc g++ clang clangd clang-format clang-tidy lldb llvm-config mlir-opt bolt flang flang-new; do
    verify_tool_with_path "$t" --version
  done
  verify_lld_version

  if verify_cross_mode_requested; then
    verify_all_cross_target_versions
    if declare -F verify_cross_llvm_targets >/dev/null 2>&1; then
      verify_cross_llvm_targets
    fi
  fi

  log "Reminder: source <sdk>/setup-env.sh before using Vulkan"
}
