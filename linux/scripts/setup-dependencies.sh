#!/usr/bin/env bash
set -euo pipefail


# --- make apt non-interactive and robust for docker builds -------------------
export DEBIAN_FRONTEND=noninteractive
export TZ=Etc/UTC                # avoid tzdata prompts if tzdata gets pulled
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
APT_FLAGS=(-yq --no-install-recommends "${APT_OPTS[@]}")

# -----------------------------------------------------------------------------
# setup-dependencies.sh
#
# Installs all required dependencies for building the project on Linux.
# Works both inside and outside GitHub Actions runners.
# see here:
# https://vulkan.lunarg.com/doc/sdk/1.4.321.1/linux/getting_started.html
# Usage:
#   ./setup-dependencies.sh [vulkan-version]
#   vulkan-version (optional): e.g. "1.3.296" (default: 1.3.296)
# -----------------------------------------------------------------------------

# Default Vulkan version
VULKAN_VERSION="1.4.321.1"
if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [vulkan-version]" >&2
  exit 1
elif [ "$#" -eq 1 ]; then
  VULKAN_VERSION="$1"
fi

# Detect system architecture and distribution
ARCH="$(uname -m)"
DISTRO="$(lsb_release -cs)"
echo "Detected architecture: $ARCH"
echo "Detected distribution codename: $DISTRO"

# Detect if sudo is required
SUDO=""
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script requires root privileges or sudo. Aborting." >&2
    exit 1
  fi
fi

# Utility: update package database
echo "Refreshing package databases..."
$SUDO apt-get update -y

# Install basic tools
echo "Installing core tools..."
$SUDO apt-get install "${APT_FLAGS[@]}" -y wget curl gpg lsb-release ca-certificates gnupg apt-transport-https
# for debian packaging
$SUDO apt-get install "${APT_FLAGS[@]}" -y dpkg-dev fakeroot binutils
$SUDO apt update -y
$SUDO apt-get install "${APT_FLAGS[@]}" -y google-perftools libgoogle-perftools-dev
# optional: für Flamegraphs
$SUDO apt-get install "${APT_FLAGS[@]}" -y graphviz

# -----------------------------------------------------------------------------
# Install CMake (latest from Kitware)
# -----------------------------------------------------------------------------
# Purge older distro cmake if present (ignore errors)
$SUDO apt-get purge --auto-remove -y cmake || true
$SUDO apt-get update -y
echo "Installing latest CMake..."
KITWARE_KEY=/usr/share/keyrings/kitware-archive-keyring.gpg
wget -qO - https://apt.kitware.com/keys/kitware-archive-latest.asc \
| gpg --dearmor \
| $SUDO tee "$KITWARE_KEY" >/dev/null
echo "deb [signed-by=$KITWARE_KEY] https://apt.kitware.com/ubuntu $DISTRO main" \
| $SUDO tee /etc/apt/sources.list.d/kitware.list >/dev/null
$SUDO apt-get update -y
$SUDO apt-get install "${APT_FLAGS[@]}" -y cmake
cmake --version

# desired tool versions
LLVM_WANTED=21        # for the apt.llvm.org helper (llvm.sh)
CLANG_WANTED=21       # for update-alternatives clang/clang++
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    
# minimal prerequisites
$SUDO apt-get update -y
$SUDO apt-get install "${APT_FLAGS[@]}" -y --no-install-recommends wget gnupg lsb-release ca-certificates

# Add the LLVM apt repo using the official helper (non-interactive)
wget -qO- https://apt.llvm.org/llvm.sh | $SUDO bash -s -- "${LLVM_WANTED}" all

$SUDO apt-get update

# clang
if [ -x "/usr/bin/clang-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/clang clang /usr/bin/clang-"${CLANG_WANTED}" 100
  $SUDO update-alternatives --set clang /usr/bin/clang-"${CLANG_WANTED}"
fi

# clang++
if [ -x "/usr/bin/clang++-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-"${CLANG_WANTED}" 100
  $SUDO update-alternatives --set clang++ /usr/bin/clang++-"${CLANG_WANTED}"
fi

# clang-tidy
if [ -x "/usr/bin/clang-tidy-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/clang-tidy clang-tidy /usr/bin/clang-tidy-"${CLANG_WANTED}" 100
fi

# clang-format
if [ -x "/usr/bin/clang-format-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/clang-format clang-format /usr/bin/clang-format-"${CLANG_WANTED}" 100
fi

# llvm-profdata
if [ -x "/usr/bin/llvm-profdata-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/llvm-profdata llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}" 100
  $SUDO update-alternatives --set llvm-profdata /usr/bin/llvm-profdata-"${CLANG_WANTED}"
fi

# llvm-cov
if [ -x "/usr/bin/llvm-cov-${CLANG_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/llvm-cov llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}" 100
  $SUDO update-alternatives --set llvm-cov /usr/bin/llvm-cov-"${CLANG_WANTED}"
fi

# Verify
clang --version
clang++ --version

# Install latest GCC
GCC_WANTED=14  # or 13, adjust as needed
$SUDO apt-get install "${APT_FLAGS[@]}" -y --no-install-recommends \
  gcc-"${GCC_WANTED}" \
  g++-"${GCC_WANTED}" \
  gfortran-"${GCC_WANTED}"

# Set GCC as default using update-alternatives
if [ -x "/usr/bin/gcc-${GCC_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-"${GCC_WANTED}" 100
  $SUDO update-alternatives --set gcc /usr/bin/gcc-"${GCC_WANTED}"
fi

if [ -x "/usr/bin/g++-${GCC_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-"${GCC_WANTED}" 100
  $SUDO update-alternatives --set g++ /usr/bin/g++-"${GCC_WANTED}"
fi

if [ -x "/usr/bin/gcov-${GCC_WANTED}" ]; then
  $SUDO update-alternatives --install /usr/bin/gcov gcov /usr/bin/gcov-"${GCC_WANTED}" 100
  $SUDO update-alternatives --set gcov /usr/bin/gcov-"${GCC_WANTED}"
fi

# Verify
gcc --version
g++ --version

install_vulkan_tarball() {
  local version="$1"
  local arch_suffix="x86_64"
  
  echo "Installing Vulkan SDK ${version} via tarball for ${ARCH}..."
  
  # Install prerequisite packages for tarball installation
  echo "Installing tarball prerequisites..."
  $SUDO apt-get install "${APT_FLAGS[@]}" -y xz-utils libglm-dev libxcb-dri3-0 \
    libxcb-present0 libpciaccess0 libpng-dev libxcb-keysyms1-dev \
    libxcb-dri3-dev libx11-dev g++ gcc libwayland-dev \
    libxrandr-dev libxcb-randr0-dev libxcb-ewmh-dev git \
    python3 bison libx11-xcb-dev liblz4-dev libzstd-dev \
    ocaml ninja-build pkg-config libxml2-dev \
    wayland-protocols python3-jsonschema clang-format qtbase5-dev qt6-base-dev \
    libxcb-xinput0 libxcb-xinerama0 libxcb-cursor-dev
  
  # Create Vulkan directory
  # local vulkan_dir="""
  # mkdir -p "$vulkan_dir"
  #cd "$vulkan_dir"
  
  # Download tarball
  local tarball_name="vulkansdk-linux-${arch_suffix}-${version}.tar.xz"
  local download_url="https://sdk.lunarg.com/sdk/download/${version}/linux/${tarball_name}"
  
  echo "Downloading ${tarball_name}..."
  if ! wget --timeout=30 --tries=3 -q "$download_url" -O "$tarball_name"; then
    echo "Failed to download Vulkan SDK from: $download_url" >&2
    echo "Please check if the version ${version} exists at https://vulkan.lunarg.com/" >&2
    exit 1
  fi
  
  # Verify download (optional - you might want to add sha256 verification here)
  if [ ! -f "$tarball_name" ] || [ ! -s "$tarball_name" ]; then
    echo "Failed to download Vulkan SDK tarball or file is empty" >&2
    exit 1
  fi
  
  echo "Successfully downloaded $(du -h "$tarball_name" | cut -f1) tarball"
  
  # Extract tarball
  echo "Extracting Vulkan SDK..."
  tar xf "$tarball_name"
  
  # Clean up tarball
  rm "$tarball_name"
  
  # Set up environment for current session
  local sdk_path="${version}" #${vulkan_dir}/
  if [ -d "$sdk_path" ]; then
    echo "Vulkan SDK extracted to: $sdk_path"
    echo ""
    echo "To use the Vulkan SDK, run the following command in each terminal session:"
    echo "  source ${sdk_path}/setup-env.sh"
    echo ""
    echo "Or add this to your ~/.bashrc or ~/.profile for automatic setup:"
    echo "  echo 'source ${sdk_path}/setup-env.sh' >> ~/.bashrc"
    echo ""
    echo "You can also build all SDK components from source using:"
    echo "  cd ${sdk_path} && ./vulkansdk"
  else
    echo "Failed to extract Vulkan SDK properly" >&2
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Install Vulkan SDK (via tarball for all architectures)
# -----------------------------------------------------------------------------
echo "Installing Vulkan SDK version ${VULKAN_VERSION} via tarball for architecture $ARCH..."

if [ "$ARCH" == "x86_64" ] || [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  install_vulkan_tarball "$VULKAN_VERSION"
else
  echo "Unknown or unsupported architecture: $ARCH. Skipping Vulkan SDK." >&2
fi

if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
  cd "${VULKAN_VERSION}"
  chmod +x vulkansdk
  echo "Running .vulkansdk to build SDK components from source... means we are not on x86_64"
  echo "Add the non user interaction flag -y to avoid prompts"
  sed -E -i.bak \
    -e '/\bapt(-get)?[[:space:]]+install\b/ { /(-y|--assume-yes|--assumeyes|--yes)/! s/(\bapt(-get)?[[:space:]]+install\b)/\1 -y/ }' \
    -e '/\bdnf[[:space:]]+install\b/     { /(-y|--assumeyes|--assume-yes|--yes)/! s/(\bdnf[[:space:]]+install\b)/\1 -y/ }' \
    -e '/\bpacman[[:space:]]+-S\b/         { /(--noconfirm|-y)/! s/(\bpacman[[:space:]]+-S\b)/\1 -y/ }' \
    ./vulkansdk
  ./vulkansdk -j $(nproc) \
    glslang vulkan-tools vulkan-headers vulkan-loader \
    vulkan-validationlayers shaderc spirv-headers spirv-tools \
    vulkan-extensionlayer volk vma vcv vul slang
fi

# -----------------------------------------------------------------------------
# Install additional dependencies
# -----------------------------------------------------------------------------
echo "Installing GLFW, rendering, and build-tool dependencies..."
$SUDO apt-get install "${APT_FLAGS[@]}" -y \
  libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libglu1-mesa-dev \
  freeglut3-dev mesa-common-dev mesa-utils wayland-protocols libwayland-dev \
  libxkbcommon-dev libglx-mesa0 ninja-build ccache sccache iwyu graphviz \
  doxygen libosmesa6-dev gcovr clang llvm

# Confirm key tools
echo "Installed versions:"
cmake --version
ccache --version | head -n1
gcc --version | head -n1
g++ --version | head -n1
clang --version | head -n1

echo "All dependencies installed successfully."

echo ""
echo "IMPORTANT: Remember to source the setup script before using Vulkan:"
echo "  source ~/vulkan/${VULKAN_VERSION}/setup-env.sh"