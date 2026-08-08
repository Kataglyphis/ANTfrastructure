#!/usr/bin/env bash
set -euo pipefail

# setup-host-deps.sh
# Manual developer-onboarding helper: installs common host development
# dependencies (toolchains, coverage/analysis tooling) across Linux package
# managers (apt/yum/dnf/pacman). Run by hand; not invoked by CI or the build.

SCRIPT_NAME=$(basename "$0")

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME

Installs development/runtime packages and toolchain utilities.
Supports apt-get, yum, dnf, and pacman.

Run as a normal user (sudo is used inside) or as root.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_usage
  exit 0
fi

install_base_packages() {
  echo "[1/4] Updating package lists..."
  sudo apt-get update -qq

  BASE_PACKAGES=(
    curl
    git
    unzip
    xz-utils
    zip
    libglu1-mesa
    clang
    cmake
    ninja-build
    pkg-config
    libgtk-3-dev
    liblzma-dev
    libstdc++-12-dev
  )

  echo "[2/4] Installing base packages: ${BASE_PACKAGES[*]}"
  sudo apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}"

  sudo apt-get install -y --no-install-recommends sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm valgrind
  sudo apt-get install -y --no-install-recommends dpkg-dev fakeroot binutils
  sudo apt-get install -y --no-install-recommends python3-pip
}

# Load the VERIFIED repo helpers (repos.sh pins the Kitware and apt.llvm.org
# key sha256s via download_verified_file). The old inline wget|gpg|tee blocks
# here fetched the SAME keys unverified — supply-chain audit findings #5/#6:
# one repo, two call sites, one verified and one not.
_shd_source_repo_helpers() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "${dir}/common.sh"
  # shellcheck disable=SC1091
  source "${dir}/repos.sh"
}

setup_kitware_repo() {
  echo "Installing latest CMake via the VERIFIED Kitware repo helper"
  sudo apt-get purge --auto-remove -y cmake || true
  _shd_source_repo_helpers
  add_kitware_repo
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends cmake
  cmake --version
}

load_toolchain_versions() {
  _core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../01-core"
  _versions_env="${_core_dir}/versions.env"
  if [ -f "${_versions_env}" ]; then
    # shellcheck disable=SC1091
    source "${_core_dir}/load-versions-env.sh"
    load_versions_env "${_versions_env}"
    LLVM_WANTED="${LLVM_RELEASE%%.*}"
    CLANG_WANTED="${LLVM_RELEASE%%.*}"
    GCC_WANTED="${GCC_VERSION%%.*}"
  else
    LLVM_WANTED=22
    CLANG_WANTED=22
    GCC_WANTED=16
  fi
  export DEBIAN_FRONTEND=noninteractive
}

# Register a versioned tool as the default alternative, if installed.
_register_alternative() {
  local -a names=("$@")
  local tool="${names[0]}"
  local version="${names[1]}"
  local weight="${names[2]:-100}"
  local -a extra=("${names[@]:3}")
  local binary="/usr/bin/${tool}-${version}"

  [ -x "${binary}" ] || return 0
  sudo update-alternatives --install "/usr/bin/${tool}" "${tool}" "${binary}" "${weight}"
  sudo update-alternatives --set "${tool}" "${binary}"
  for alt in "${extra[@]:-}"; do
    [ -x "/usr/bin/${alt}-${version}" ] || continue
    sudo update-alternatives --install "/usr/bin/${alt}" "${alt}" "/usr/bin/${alt}-${version}" "${weight}"
  done
}

install_llvm_and_alternatives() {
  sudo apt-get install -y --no-install-recommends wget gnupg lsb-release ca-certificates
  # add_llvm_repo (repos.sh) replaces the old `wget llvm.sh | sudo bash`: the
  # remote script was unpinned root execution AND skipped the apt pin to
  # ${LLVM_RELEASE}* that the helper applies (supply-chain audit finding #5).
  _shd_source_repo_helpers
  add_llvm_repo
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    "clang-${LLVM_WANTED}" "clang-tidy-${LLVM_WANTED}" "clang-format-${LLVM_WANTED}" \
    "llvm-${LLVM_WANTED}" "lld-${LLVM_WANTED}" "lldb-${LLVM_WANTED}"

  # Registers clang and, as slaves-by-name, clang-tidy/clang-format/llvm-profdata/
  # llvm-cov (each --installed when its versioned binary exists).
  _register_alternative clang "${CLANG_WANTED}" 100 clang-tidy clang-format llvm-profdata llvm-cov

  clang --version
  clang++ --version
}

install_gcc_and_alternatives() {
  sudo apt-get install -y --no-install-recommends \
    gcc-"${GCC_WANTED}" \
    g++-"${GCC_WANTED}" \
    gfortran-"${GCC_WANTED}"

  _register_alternative gcc "${GCC_WANTED}" 100
  _register_alternative g++ "${GCC_WANTED}" 100
  _register_alternative gcov "${GCC_WANTED}" 100

  gcc --version
  g++ --version
}

cleanup_apt() {
  echo "[3/4] Cleaning up..."
  sudo apt-get clean
  sudo rm -rf /var/lib/apt/lists/*
}

install_via_apt() {
  install_base_packages
  setup_kitware_repo
  load_toolchain_versions
  install_llvm_and_alternatives
  install_gcc_and_alternatives
  cleanup_apt
}

if command -v apt-get >/dev/null 2>&1; then
  echo "Detected apt-get. Installing via apt-get..."
  install_via_apt

elif command -v yum >/dev/null 2>&1; then
  echo "Detected yum. Installing via yum..."
  sudo yum install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake curl git unzip xz python3-pip

elif command -v dnf >/dev/null 2>&1; then
  echo "Detected dnf. Installing via dnf..."
  sudo dnf install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake curl git unzip xz python3-pip

elif command -v pacman >/dev/null 2>&1; then
  echo "Detected pacman. Installing via pacman..."
  sudo pacman -Sy --noconfirm sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm cmake curl git unzip xz python-pip

else
  echo "No supported package manager found. Please install dependencies manually." >&2
  exit 1
fi

echo "Checking for gcov..."
gcov --version || true
which gcov || true

echo "Installing gcovr (coverage reporting tool)..."
if command -v uv >/dev/null 2>&1; then
  uv pip install --system gcovr || uv tool install gcovr
elif command -v pip3 >/dev/null 2>&1; then
  pip3 install --upgrade --break-system-packages --user gcovr || pip3 install --upgrade --user gcovr
elif command -v pip >/dev/null 2>&1; then
  pip install --upgrade --break-system-packages --user gcovr || pip install --upgrade --user gcovr
else
  echo "pip not found. Skipping gcovr installation."
fi

echo "All done. Packages installed successfully."
