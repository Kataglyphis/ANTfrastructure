#!/usr/bin/env bash
# verify.sh - print versions

verify_summary() {
  log "Installed versions:"
  tool_version cmake --version
  tool_version ccache --version
  tool_version gcc --version
  tool_version g++ --version
  tool_version clang --version
  tool_version clangd --version
  tool_version clang-format --version
  tool_version clang-tidy --version
  tool_version lld --version
  tool_version lldb --version
  tool_version llvm-config --version
  tool_version mlir-opt --version
  tool_version bolt --version
  tool_version flang --version
  tool_version flang-new --version
  log "Reminder: source <sdk>/setup-env.sh before using Vulkan"
}