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
  log "Adding LLVM apt repo via helper (version ${LLVM_WANTED})"
  apt_install wget gnupg lsb-release ca-certificates
  wget -qO- https://apt.llvm.org/llvm.sh | $SUDO bash -s -- "${LLVM_WANTED}" all
  APT_UPDATED="" # force refresh
}