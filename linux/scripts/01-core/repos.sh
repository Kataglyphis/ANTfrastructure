#!/usr/bin/env bash
# repos.sh - add external apt repositories
[ -n "${_REPOS_SH_LOADED:-}" ] && return 0
_REPOS_SH_LOADED=1

repo_http_status() {
  local url="$1"
  curl -sSL -o /dev/null -w '%{http_code}' "$url"
}

ensure_repo_release_exists() {
  local url="$1"
  local label="$2"
  local status

  status="$(repo_http_status "$url" || true)"
  case "$status" in
    200) return 0 ;;
    404) die "${label} not available: ${url}" ;;
    *) die "Failed to query ${label}: ${url} (HTTP ${status:-unknown})" ;;
  esac
}

write_keyring_from_armored_key() {
  local armored_key="$1"
  local keyring_path="$2"

  $SUDO mkdir -p "$(dirname "${keyring_path}")"
  gpg --dearmor < "${armored_key}" | $SUDO tee "${keyring_path}" >/dev/null
  $SUDO chmod 0644 "${keyring_path}"
}

llvm_repo_inrelease_url() {
  local distro="${1:-$DISTRO}"
  printf '%s' "https://apt.llvm.org/${distro}/dists/llvm-toolchain-${distro}-${LLVM_WANTED}/InRelease"
}

llvm_repo_available() {
  local distro="${1:-$DISTRO}"
  local status

  status="$(repo_http_status "$(llvm_repo_inrelease_url "${distro}")" || true)"
  case "$status" in
    200) return 0 ;;
    404) return 1 ;;
    *) die "Failed to query apt.llvm.org for ${distro} (HTTP ${status:-unknown})" ;;
  esac
}

add_kitware_repo() {
  log "Adding Kitware apt repo"
  apt_install curl gpg gnupg ca-certificates lsb-release apt-transport-https

  local key=/usr/share/keyrings/kitware-archive-keyring.gpg
  local release_url="https://apt.kitware.com/ubuntu/dists/${DISTRO}/InRelease"
  local key_tmp

  ensure_repo_release_exists "${release_url}" "Kitware apt repo for ${DISTRO}"

  key_tmp="$(mktemp)"
  download_verified_file \
    "https://apt.kitware.com/keys/kitware-archive-latest.asc" \
    "801bc629e356c3c96f184351272914222ce427777400fa7d1baed3ab180b3e3b" \
    "${key_tmp}"
  write_keyring_from_armored_key "${key_tmp}" "$key"
  rm -f "${key_tmp}"

  echo "deb [signed-by=$key] https://apt.kitware.com/ubuntu $DISTRO main" | $SUDO tee /etc/apt/sources.list.d/kitware.list >/dev/null
  APT_UPDATED="" # force refresh
  export APT_UPDATED
}

add_llvm_repo() {
  log "Adding LLVM apt repo (version ${LLVM_WANTED})"
  apt_install curl gpg gnupg lsb-release ca-certificates apt-transport-https

  llvm_repo_available "${DISTRO}" || die "apt.llvm.org does not publish LLVM ${LLVM_WANTED} packages for Ubuntu ${DISTRO}"

  local key=/usr/share/keyrings/apt.llvm.org.gpg
  local key_tmp
  key_tmp="$(mktemp)"

  download_verified_file \
    "https://apt.llvm.org/llvm-snapshot.gpg.key" \
    "8b2a587ffd672c4687e7581dad4b2f6c1bb2ad6b480cd9771ba2ff48e0b8c75d" \
    "${key_tmp}"
  write_keyring_from_armored_key "${key_tmp}" "${key}"
  rm -f "${key_tmp}"

  $SUDO mkdir -p /etc/apt/sources.list.d
  echo "deb [signed-by=${key}] https://apt.llvm.org/${DISTRO}/ llvm-toolchain-${DISTRO}-${LLVM_WANTED} main" | $SUDO tee /etc/apt/sources.list.d/apt.llvm.org.list >/dev/null

  APT_UPDATED="" # force refresh
  export APT_UPDATED
}
