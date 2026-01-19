#!/usr/bin/env bash
set -euo pipefail

# build-and-make-default-gcc15.sh
# Builds GCC 15.x from source and registers it as the system default via update-alternatives.
# Default build directory is $HOME/tmp2/gcc-build-<version> (no /tmp usage).
#
# Usage:
#   ./build-and-make-default-gcc15.sh
#   GCC_VERSION=15.2.0 PREFIX=/opt/gcc-15 BUILD_DIR="$HOME/tmp2/mybuild" JOBS=4 ./build-and-make-default-gcc15.sh

GCC_VERSION="${GCC_VERSION:-15.2.0}"

# DEFAULT: use a tmp2 directory in the user's home — avoids /tmp entirely
BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${GCC_VERSION}}"
PREFIX="${PREFIX:-/opt/gcc-${GCC_VERSION}}"
JOBS="${JOBS:-$(nproc)}"

TARBALL="gcc-${GCC_VERSION}.tar.xz"
DOWNLOAD_BASE="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}"
TARBALL_URL="${DOWNLOAD_BASE}/${TARBALL}"
SHA_URL="${DOWNLOAD_BASE}/sha512.sum"
SIG_URL="${DOWNLOAD_BASE}/${TARBALL}.sig"

export DEBIAN_FRONTEND=noninteractive

echo "=== Build & set GCC ${GCC_VERSION} as system default ==="
echo "Prefix: ${PREFIX}"
echo "Build dir: ${BUILD_DIR}"
echo "Parallel jobs: ${JOBS}"
echo

# 1) Install build deps (Ubuntu/Debian)
echo "Installing build dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential \
  g++ \
  make \
  wget \
  xz-utils \
  ca-certificates \
  libgmp-dev \
  libmpfr-dev \
  libmpc-dev \
  libisl-dev \
  libzstd-dev \
  texinfo \
  flex \
  bison \
  python3 \
  libexpat1-dev \
  libncurses-dev \
  libelf-dev \
  patch \
  git

# 2) Prepare build directory (no /tmp used)
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

echo "Downloading GCC sources to ${BUILD_DIR}..."
if [ ! -f "${TARBALL}" ]; then
  wget -c "${TARBALL_URL}"
else
  echo "Tarball already exists: ${TARBALL}"
fi

echo "Attempting SHA512 verification..."
if wget -q --spider "${SHA_URL}"; then
  wget -c "${SHA_URL}" -O sha512.sum || true
  if grep -q "${TARBALL}" sha512.sum 2>/dev/null; then
    grep "${TARBALL}" sha512.sum > "${TARBALL}.sha512"
    if sha512sum -c --status "${TARBALL}.sha512"; then
      echo "SHA512 OK."
    else
      echo "ERROR: SHA512 mismatch - aborting." >&2
      exit 1
    fi
  else
    echo "WARNING: tarball entry not found in sha512.sum; continuing without SHA check." >&2
  fi
else
  echo "No sha512.sum found on server; continuing." >&2
fi

# Optional: download signature for manual GPG verification
if wget -q --spider "${SIG_URL}"; then
  echo "Signature available at ${SIG_URL} (downloading). You can verify with gpg if you wish."
  wget -c "${SIG_URL}" || true
else
  echo "No .sig found or accessible."
fi

# 3) Extract and configure
echo "Extracting ${TARBALL}..."
rm -rf "gcc-${GCC_VERSION}" "gcc-${GCC_VERSION}-build"
tar -xf "${TARBALL}"

BUILD_SUBDIR="${BUILD_DIR}/gcc-${GCC_VERSION}-build"
mkdir -p "${BUILD_SUBDIR}"
cd "${BUILD_SUBDIR}"

echo "Configuring build (languages: c,c++,fortran)..."
CONFIG_CMD=(
  "../gcc-${GCC_VERSION}/configure"
  "--prefix=${PREFIX}"
  "--enable-languages=c,c++,fortran"
  "--disable-multilib"
  "--enable-checking=release"
  "--enable-bootstrap"
  "--with-system-zlib"
)
printf '%q ' "${CONFIG_CMD[@]}"; echo
"${CONFIG_CMD[@]}"

# 4) Build & install
echo "Building (this will take a long time)..."
make -j"${JOBS}"

echo "Installing to ${PREFIX}..."
mkdir -p "${PREFIX}"
make install

# 5) Register with update-alternatives and set as default
echo
echo "Registering installed binaries with update-alternatives..."
ALTS_PRIORITY=150

GCC_BIN="${PREFIX}/bin/gcc"
GXX_BIN="${PREFIX}/bin/g++"
CPP_BIN="${PREFIX}/bin/cpp"
GCOV_BIN="${PREFIX}/bin/gcov"
GFORTRAN_BIN="${PREFIX}/bin/gfortran"

if [ ! -x "${GCC_BIN}" ]; then
  echo "ERROR: expected gcc at ${GCC_BIN} but not found or not executable." >&2
  exit 1
fi

ALT_CMD=(update-alternatives --install /usr/bin/gcc gcc "${GCC_BIN}" "${ALTS_PRIORITY}")
if [ -x "${GXX_BIN}" ]; then ALT_CMD+=(--slave /usr/bin/g++ g++ "${GXX_BIN}"); fi
if [ -x "${CPP_BIN}" ]; then ALT_CMD+=(--slave /usr/bin/cpp cpp "${CPP_BIN}"); fi
if [ -x "${GCOV_BIN}" ]; then ALT_CMD+=(--slave /usr/bin/gcov gcov "${GCOV_BIN}"); fi
if [ -x "${GFORTRAN_BIN}" ]; then ALT_CMD+=(--slave /usr/bin/gfortran gfortran "${GFORTRAN_BIN}"); fi

echo "Running: ${ALT_CMD[*]}"
"${ALT_CMD[@]}"

echo "Registering /usr/bin/cc to point to ${GCC_BIN} and setting alternatives..."
update-alternatives --install /usr/bin/cc cc "${GCC_BIN}" "${ALTS_PRIORITY}"
update-alternatives --set cc "${GCC_BIN}"

if [ -x "${GXX_BIN}" ]; then update-alternatives --set g++ "${GXX_BIN}" || true; fi
update-alternatives --set gcc "${GCC_BIN}"

echo "update-alternatives registration complete."

# 6) Add library path to loader and run ldconfig
CONF_FILE="/etc/ld.so.conf.d/gcc-${GCC_VERSION}.conf"
: > "${CONF_FILE}"

if [ -d "${PREFIX}/lib64" ]; then
  echo "${PREFIX}/lib64" >> "${CONF_FILE}"
fi
if [ -d "${PREFIX}/lib" ]; then
  echo "${PREFIX}/lib" >> "${CONF_FILE}"
fi

if [ -s "${CONF_FILE}" ]; then
  echo "Adding GCC runtime libs from ${PREFIX} to loader path and running ldconfig..."
  ldconfig
else
  rm -f "${CONF_FILE}"
  echo "No GCC lib directories found under ${PREFIX}; skipping ldconfig step." >&2
fi

# 7) Quick verification
echo
echo "Verification: which gcc && gcc --version && g++ --version (if present)"
command -v gcc || true
gcc --version || true
if command -v g++ >/dev/null 2>&1; then
  g++ --version || true
fi
