#!/usr/bin/env bash
# verify.sh - print versions

verify_summary() {
  log "Installed versions:"
  cmake --version || true
  ccache --version | head -n1 || true
  gcc --version | head -n1 || true
  g++ --version | head -n1 || true
  clang --version | head -n1 || true
  log "Reminder: source <sdk>/setup-env.sh before using Vulkan"
}