#!/usr/bin/env bash
# llvm.sh - LLVM/Clang toolchain

llvm_cross_triplet() {
  case "$1" in
    arm64|aarch64) printf '%s' "aarch64-linux-gnu" ;;
    riscv64) printf '%s' "riscv64-linux-gnu" ;;
    amd64|x86_64) printf '%s' "x86_64-linux-gnu" ;;
    *) return 1 ;;
  esac
}

install_cross_clang_wrappers() {
  local targets_raw="${CROSS_TARGETS:-arm64,riscv64}"
  local target triplet sysroot wrapper

  [ "${BUILD_MODE:-native}" = "cross" ] || return 0

  for target in ${targets_raw//,/ }; do
    triplet="$(llvm_cross_triplet "$target")" || {
      log "Skipping unsupported LLVM cross target: ${target}"
      continue
    }
    sysroot="/usr/${triplet}"

    wrapper="/usr/local/bin/clang-${target}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/clang --target=${triplet} --sysroot=${sysroot} "\$@"
EOF
    chmod +x "${wrapper}"

    wrapper="/usr/local/bin/clang++-${target}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/clang++ --target=${triplet} --sysroot=${sysroot} "\$@"
EOF
    chmod +x "${wrapper}"
  done
}

apt_has_package() {
  local pkg="$1"
  apt-cache show "$pkg" >/dev/null 2>&1
}

apt_install_available() {
  local pkgs=()
  local pkg
  for pkg in "$@"; do
    if apt_has_package "$pkg"; then
      pkgs+=("$pkg")
    else
      log "Skipping missing package: ${pkg}"
    fi
  done
  if [ "${#pkgs[@]}" -gt 0 ]; then
    apt_install "${pkgs[@]}"
  fi
}

install_llvm_clang_minimal() {
  log "Installing minimal LLVM/Clang ${CLANG_WANTED}"
  add_llvm_repo
  apt_update_once

  apt_install_available \
    "clang-${CLANG_WANTED}" \
    "lld-${CLANG_WANTED}" \
    "lldb-${CLANG_WANTED}" \
    "llvm-${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}-dev" \
    "llvm-${LLVM_WANTED}-runtime" \
    "libclang-${CLANG_WANTED}-dev" \
    "libclang1-${CLANG_WANTED}"
}

install_llvm_clang_full() {
  log "Installing full LLVM/Clang ${CLANG_WANTED} (LLVM ${LLVM_WANTED})"
  add_llvm_repo
  apt_update_once

  # Base LLVM + Clang toolchain
  apt_install_available \
    "libllvm${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}-dev" \
    "llvm-${LLVM_WANTED}-runtime" \
    "clang-${CLANG_WANTED}" \
    "clang-tools-${CLANG_WANTED}" \
    "clangd-${CLANG_WANTED}" \
    "clang-tidy-${CLANG_WANTED}" \
    "clang-format-${CLANG_WANTED}" \
    "python3-clang-${CLANG_WANTED}" \
    "libclang-common-${CLANG_WANTED}-dev" \
    "libclang-${CLANG_WANTED}-dev" \
    "libclang1-${CLANG_WANTED}" \
    "lld-${CLANG_WANTED}" \
    "lldb-${CLANG_WANTED}"

  # Commonly useful extras from apt.llvm.org (installed when present)
  apt_install_available \
    "libclang-rt-${CLANG_WANTED}-dev" \
    "libpolly-${CLANG_WANTED}-dev" \
    "libfuzzer-${CLANG_WANTED}-dev" \
    "libc++-${CLANG_WANTED}-dev" \
    "libc++abi-${CLANG_WANTED}-dev" \
    "libomp-${CLANG_WANTED}-dev" \
    "libclc-${CLANG_WANTED}-dev" \
    "libunwind-${CLANG_WANTED}-dev" \
    "libmlir-${CLANG_WANTED}-dev" \
    "mlir-${CLANG_WANTED}-tools" \
    "libbolt-${CLANG_WANTED}-dev" \
    "bolt-${CLANG_WANTED}" \
    "flang-${CLANG_WANTED}" \
    "libllvmlibc-${CLANG_WANTED}-dev"
}

install_llvm_clang() {
  # Default to a complete install; override with LLVM_INSTALL_PROFILE=minimal if desired.
  local profile="${LLVM_INSTALL_PROFILE:-full}"
  case "$profile" in
    full)    install_llvm_clang_full ;;
    minimal) install_llvm_clang_minimal ;;
    *) die "Unknown LLVM_INSTALL_PROFILE: ${profile} (expected: full|minimal)" ;;
  esac

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

  # Show versions (non-fatal)
  tool_version clang --version
  tool_version clang++ --version
  tool_version clangd --version
  tool_version clang-format --version
  tool_version clang-tidy --version
  tool_version lld --version
  tool_version lldb --version
  tool_version llvm-config --version

  # Useful LLVM/MLIR/BOLT/Flang tools (present depending on installed packages)
  tool_version llvm-ar --version
  tool_version llvm-nm --version
  tool_version llvm-objdump --version
  tool_version llvm-profdata --version
  tool_version opt --version
  tool_version llc --version
  tool_version mlir-opt --version
  tool_version bolt --version
  tool_version flang --version
  tool_version flang-new --version

  install_cross_clang_wrappers
}

