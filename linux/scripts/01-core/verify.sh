#!/usr/bin/env bash
# verify.sh - print versions

verify_tool_with_path() {
  local tool="$1"
  shift || true

  if command -v "$tool" >/dev/null 2>&1; then
    log "${tool} -> $(command -v "$tool")"
    "$tool" "$@" || true
  fi
}

verify_cross_target_versions() {
  local target_arch="${ARCH:-${TARGETARCH:-${TARGET_ARCH:-}}}"
  local triplet=""
  local clang_target=""
  local requested_major="${GCC_WANTED%%.*}"
  local reported_version=""

  case "$target_arch" in
    amd64|x86_64)
      triplet="x86_64-linux-gnu"
      clang_target="amd64"
      ;;
    arm64|aarch64)
      triplet="aarch64-linux-gnu"
      clang_target="arm64"
      ;;
    riscv64|riscv|rv64*)
      triplet="riscv64-linux-gnu"
      clang_target="riscv64"
      ;;
    *)
      return 0
      ;;
  esac

  log "Target cross toolchain for ARCH=${target_arch}:"
  verify_tool_with_path "${triplet}-gcc" --version
  verify_tool_with_path "${triplet}-g++" --version
  verify_tool_with_path "${triplet}-ar" --version
  if command -v "${triplet}-g++" >/dev/null 2>&1; then
    reported_version="$("${triplet}-g++" -dumpfullversion -dumpversion 2>/dev/null || true)"
    reported_version="${reported_version%%[[:space:]]*}"
    if [ -n "${requested_major}" ] && [ -n "${reported_version}" ] && [ "${reported_version%%.*}" != "${requested_major}" ]; then
      log "Cross GCC request mismatch: GCC_WANTED=${GCC_WANTED}, but ${triplet}-g++ reports ${reported_version}"
    fi
  fi
  if [ -n "${LIBRARY_PATH:-}" ]; then
    log "Cross LIBRARY_PATH=${LIBRARY_PATH}"
  fi
  verify_tool_with_path "clang-${clang_target}" --version
  verify_tool_with_path "clang++-${clang_target}" --version
}

verify_summary() {
  log "Installed versions:"
  tool_version cmake --version
  tool_version ccache --version

  if [ "${BUILD_MODE:-native}" = "cross" ]; then
    log "Host toolchain on the builder image:"
  fi
  verify_tool_with_path gcc --version
  verify_tool_with_path g++ --version
  verify_tool_with_path clang --version
  verify_tool_with_path clangd --version
  verify_tool_with_path clang-format --version
  verify_tool_with_path clang-tidy --version
  verify_tool_with_path lld --version
  verify_tool_with_path lldb --version
  verify_tool_with_path llvm-config --version
  verify_tool_with_path mlir-opt --version
  verify_tool_with_path bolt --version
  verify_tool_with_path flang --version
  verify_tool_with_path flang-new --version

  if [ "${BUILD_MODE:-native}" = "cross" ]; then
    verify_cross_target_versions
    if declare -F verify_cross_llvm_targets >/dev/null 2>&1; then
      verify_cross_llvm_targets
    fi
  fi

  log "Reminder: source <sdk>/setup-env.sh before using Vulkan"
}
