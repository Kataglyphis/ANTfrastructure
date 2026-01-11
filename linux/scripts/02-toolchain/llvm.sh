#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain

install_llvm_clang() {
  log "Installing LLVM/Clang ${CLANG_WANTED}"
  add_llvm_repo
  apt_update_once

  # Register every versioned binary we find under /usr/bin that ends with -${CLANG_WANTED}
  # and set it as the chosen alternative.
  for full in /usr/bin/*-"${CLANG_WANTED}"; do
    # if glob didn't match, "$full" may be the literal pattern; skip non-existing entries
    [ -e "$full" ] || continue

    base="$(basename "$full")"
    tool="${base%-${CLANG_WANTED}}"

    # install the alternative and force it to the new path
    $SUDO update-alternatives --install "/usr/bin/${tool}" "${tool}" "$full" 100
    $SUDO update-alternatives --set "${tool}" "$full"
  done

  # Extra LLVM packages you want installed (optional)
  apt_install lld lldb llvm llvm-dev libclang-dev

  # Show versions (non-fatal)
  clang --version || true
  clang++ --version || true
  lld --version || true
  lldb --version || true
  llvm-config --version || true
}

