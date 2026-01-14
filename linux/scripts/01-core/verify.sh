#!/usr/bin/env bash
# verify.sh - print versions

verify_summary() {
  _tool_version() {
    local cmd="$1"
    shift || true
    if command -v "$cmd" >/dev/null 2>&1; then
      "$cmd" "$@" || true
    fi
  }

  log "Installed versions:"
  _tool_version cmake --version
  _tool_version ccache --version
  _tool_version gcc --version
  _tool_version g++ --version
  _tool_version clang --version
  _tool_version clangd --version
  _tool_version clang-format --version
  _tool_version clang-tidy --version
  _tool_version lld --version
  _tool_version lldb --version
  _tool_version llvm-config --version
  _tool_version mlir-opt --version
  _tool_version bolt --version
  _tool_version flang --version
  _tool_version flang-new --version
  log "Reminder: source <sdk>/setup-env.sh before using Vulkan"
}