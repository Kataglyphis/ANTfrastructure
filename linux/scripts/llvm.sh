#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain

install_llvm_clang() {
  log "Installing LLVM/Clang ${CLANG_WANTED}"
  add_llvm_repo
  apt_update_once

  # Alternatives for versioned tools
  for tool in clang clang++ clang-tidy clang-format llvm-profdata llvm-cov; do
    if [ -x "/usr/bin/${tool}-${CLANG_WANTED}" ]; then
      $SUDO update-alternatives --install "/usr/bin/${tool}" "${tool}" "/usr/bin/${tool}-${CLANG_WANTED}" 100
      case "$tool" in
        clang|clang++|llvm-profdata|llvm-cov)
          $SUDO update-alternatives --set "${tool}" "/usr/bin/${tool}-${CLANG_WANTED}"
          ;;
      esac
    fi
  done

  # Extra LLVM tools (optional)
  apt_install lld lldb llvm llvm-dev libclang-dev
  clang --version || true
  clang++ --version || true
}