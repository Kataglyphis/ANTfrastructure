#!/usr/bin/env bash
set -euo pipefail

# setup-dependencies.sh
# Installs common development dependencies across Linux package managers.

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

if command -v apt-get >/dev/null 2>&1; then
  echo "Detected apt-get. Installing via apt-get..."

  echo "[1/3] Updating package lists..."
  sudo apt-get update -y

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

  echo "[2/3] Installing base packages: ${BASE_PACKAGES[*]}"
  sudo apt-get install -y "${BASE_PACKAGES[@]}"

  sudo apt-get update
  sudo apt-get install -y sccache ccache cppcheck iwyu lcov binutils graphviz doxygen llvm valgrind

  sudo apt-get install -y dpkg-dev fakeroot binutils
  sudo apt-get install -y python3-pip

  CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
  echo "Installing latest CMake via Kitware repo for codename: ${CODENAME}"

  sudo apt-get purge --auto-remove -y cmake || true

  sudo apt-get update
  sudo apt-get install -y wget gpg lsb-release ca-certificates

  wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/kitware-archive-keyring.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] https://apt.kitware.com/ubuntu/ ${CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/kitware.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y cmake
  cmake --version

  LLVM_WANTED=22
  CLANG_WANTED=22
  GCC_WANTED=14
  export DEBIAN_FRONTEND=noninteractive

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends wget gnupg lsb-release ca-certificates

  wget -qO- https://apt.llvm.org/llvm.sh | sudo bash -s -- "${LLVM_WANTED}" all
  sudo apt-get update

  if [ -x "/usr/bin/clang-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/clang clang /usr/bin/clang-"${CLANG_WANTED}" 100
    sudo update-alternatives --set clang /usr/bin/clang-"${CLANG_WANTED}"
  fi

  if [ -x "/usr/bin/clang++-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-"${CLANG_WANTED}" 100
    sudo update-alternatives --set clang++ /usr/bin/clang++-"${CLANG_WANTED}"
  fi

  if [ -x "/usr/bin/clang-tidy-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/clang-tidy clang-tidy /usr/bin/clang-tidy-"${CLANG_WANTED}" 100
  fi

  if [ -x "/usr/bin/clang-format-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-"${CLANG_WANTED}" 100
  fi

  if [ -x "/usr/bin/llvm-profdata-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/llvm-profdata llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}" 100
    sudo update-alternatives --set llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}"
  fi

  if [ -x "/usr/bin/llvm-cov-${CLANG_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/llvm-cov llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}" 100
    sudo update-alternatives --set llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}"
  fi

  clang --version
  clang++ --version

  sudo apt-get install -y --no-install-recommends \
    gcc-"${GCC_WANTED}" \
    g++-"${GCC_WANTED}" \
    gfortran-"${GCC_WANTED}"

  if [ -x "/usr/bin/gcc-${GCC_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-"${GCC_WANTED}" 100
    sudo update-alternatives --set gcc /usr/bin/gcc-"${GCC_WANTED}"
  fi

  if [ -x "/usr/bin/g++-${GCC_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-"${GCC_WANTED}" 100
    sudo update-alternatives --set g++ /usr/bin/g++-"${GCC_WANTED}"
  fi

  if [ -x "/usr/bin/gcov-${GCC_WANTED}" ]; then
    sudo update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-"${GCC_WANTED}" 100
    sudo update-alternatives --set gcov /usr/bin/gcov-"${GCC_WANTED}"
  fi

  gcc --version
  g++ --version

  echo "[3/3] Cleaning up..."
  sudo apt-get clean
  sudo rm -rf /var/lib/apt/lists/*

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
