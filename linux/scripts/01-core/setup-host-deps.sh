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

setup_kitware_repo() {
  CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
  echo "Installing latest CMake via Kitware repo for codename: ${CODENAME}"

  sudo apt-get purge --auto-remove -y cmake || true
  sudo apt-get install -y --no-install-recommends wget gpg lsb-release ca-certificates

  wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null

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
  wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- "${LLVM_WANTED}" all
  # llvm.sh adds new repos; refresh package lists for subsequent installs
  sudo apt-get update -qq

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
