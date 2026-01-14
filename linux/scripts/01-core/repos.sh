#!/usr/bin/env bash
# repos.sh - add external apt repositories

add_kitware_repo() {
  log "Adding Kitware apt repo"
  apt_install wget gpg gnupg ca-certificates lsb-release apt-transport-https
  local key=/usr/share/keyrings/kitware-archive-keyring.gpg
  wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc | gpg --dearmor | $SUDO tee "$key" >/dev/null
  echo "deb [signed-by=$key] https://apt.kitware.com/ubuntu $DISTRO main" | $SUDO tee /etc/apt/sources.list.d/kitware.list >/dev/null
  APT_UPDATED="" # force refresh
}

add_llvm_repo() {
  log "Adding LLVM apt repo (version ${LLVM_WANTED})"
  apt_install wget gnupg lsb-release ca-certificates

  # Install repo signing key
  # Fingerprint (from apt.llvm.org): 6084 F3CF 814B 57C1 CF12 EFD5 15CF 4D18 AF4F 7421
  $SUDO mkdir -p /etc/apt/trusted.gpg.d
  wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | $SUDO tee /etc/apt/trusted.gpg.d/apt.llvm.org.asc >/dev/null

  # Add versioned repository for the current distro codename (e.g. jammy, noble, bookworm)
  $SUDO mkdir -p /etc/apt/sources.list.d
  echo "deb http://apt.llvm.org/${DISTRO}/ llvm-toolchain-${DISTRO}-${LLVM_WANTED} main" | $SUDO tee /etc/apt/sources.list.d/apt.llvm.org.list >/dev/null

  APT_UPDATED="" # force refresh
}