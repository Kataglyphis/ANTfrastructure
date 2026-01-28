#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# build-and-make-default-gcc15.sh
# Builds GCC 15.x from source and registers it as the system default via update-alternatives.
# Default build directory is $HOME/tmp2/gcc-build-<version> (no /tmp usage).
#
# Usage:
#   ./build-and-make-default-gcc15.sh
#   GCC_VERSION=15.2.0 PREFIX=/opt/gcc-15 BUILD_DIR="$HOME/tmp2/mybuild" JOBS=4 ./build-and-make-default-gcc15.sh

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_HELPERS_LOADED=""
# Prefer shared helpers (common.sh sources parallelism.sh). In Docker builds, core scripts
# are often symlinked into this directory.
# shellcheck disable=SC1090
if [ -f "${_SCRIPT_DIR}/common.sh" ]; then
  source "${_SCRIPT_DIR}/common.sh"
  _HELPERS_LOADED=1
elif [ -f "${_SCRIPT_DIR}/../01-core/common.sh" ]; then
  # shellcheck disable=SC1090
  source "${_SCRIPT_DIR}/../01-core/common.sh"
  _HELPERS_LOADED=1
fi

# Minimal fallbacks when core helpers aren't available.
if [ -z "${_HELPERS_LOADED}" ]; then
  info() { printf '[INFO] %s\n' "$*"; }
  warn() { printf '[WARN] %s\n' "$*" >&2; }
  err()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
  die()  { err "$@"; }
  require_sudo() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
      command -v sudo >/dev/null 2>&1 || die "This script requires sudo or root."
      SUDO="sudo"
    else
      SUDO=""
    fi
  }
  apt_install() {
    ${SUDO:-} apt-get update -y
    ${SUDO:-} apt-get install -y --no-install-recommends "$@"
  }
  detect_system() { :; }
fi

on_err() {
  local line="${1:-?}"
  local cmd="${2:-?}"
  err "Command failed (line ${line}): ${cmd}"
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

usage() {
  cat <<'USAGE'
Usage:
  ./build-and-make-default-gcc15.sh [options]

Options (all also configurable via ENV):
  --keep-build         Do not delete BUILD_DIR at the end
  -h, --help           Show this help

Environment:
  GCC_VERSION              GCC version to build (default: 15.2.0)
  BUILD_DIR                Build directory (default: $HOME/tmp2/gcc-build-<version>)
  PREFIX                   Install prefix (default: /opt/gcc-<version>)
  JOBS                     Requested parallel jobs (will be capped by cgroup CPU/mem when helpers exist)
  GCC_BUILD_MB_PER_JOB     Memory cap per job for parallel build (default: 2500)
USAGE
}

KEEP_BUILD="${KEEP_BUILD:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-build) KEEP_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

GCC_VERSION="${GCC_VERSION:-15.2.0}"

# DEFAULT: use a tmp2 directory in the user's home — avoids /tmp entirely
BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${GCC_VERSION}}"
PREFIX="${PREFIX:-/opt/gcc-${GCC_VERSION}}"

require_sudo
detect_system || true

# Determine requested jobs (only if user set JOBS in the environment).
JOBS_REQUESTED=""
if [[ -n "${JOBS+x}" ]]; then
  JOBS_REQUESTED="${JOBS}"
fi

# CPU quota + optional RAM cap (if core helper exists).
if command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
  JOBS="$(compute_jobs_with_mem_cap "${JOBS_REQUESTED}" "${GCC_BUILD_MB_PER_JOB:-2500}")"
else
  JOBS="${JOBS_REQUESTED:-$(nproc || echo 1)}"
fi

TARBALL="gcc-${GCC_VERSION}.tar.xz"
DOWNLOAD_BASE="https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}"
TARBALL_URL="${DOWNLOAD_BASE}/${TARBALL}"
SHA_URL="${DOWNLOAD_BASE}/sha512.sum"
SIG_URL="${DOWNLOAD_BASE}/${TARBALL}.sig"

info "=== Build & set GCC ${GCC_VERSION} as system default ==="
info "Prefix: ${PREFIX}"
info "Build dir: ${BUILD_DIR}"
info "Parallel jobs: ${JOBS}"
info ""

# 1) Install build deps (Ubuntu/Debian)
info "Installing build dependencies..."
apt_install \
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
  wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${TARBALL_URL}"
else
  echo "Tarball already exists: ${TARBALL}"
fi

echo "Attempting SHA512 verification..."
if wget -q --spider "${SHA_URL}"; then
  wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SHA_URL}" -O sha512.sum || true
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
  wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SIG_URL}" || true
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
${SUDO} mkdir -p "${PREFIX}"
${SUDO} make install

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

# NOTE: Do NOT use --slave here. In minimal/container images, g++/cpp/gcov may
# already be managed by separate alternatives groups (or not at all). Using
# --slave can fail with exit code 2 if link groups are already configured.

echo "Registering gcc..."
${SUDO} update-alternatives --install /usr/bin/gcc gcc "${GCC_BIN}" "${ALTS_PRIORITY}"

if [ -x "${GXX_BIN}" ]; then
  echo "Registering g++..."
  ${SUDO} update-alternatives --install /usr/bin/g++ g++ "${GXX_BIN}" "${ALTS_PRIORITY}"
fi

if [ -x "${CPP_BIN}" ]; then
  echo "Registering cpp..."
  # On Ubuntu/Debian, the master link for the 'cpp' alternative may be /lib/cpp.
  # Using the wrong master link can trigger a link-group rename and sometimes
  # fail in minimal/container setups.
  CPP_LINK="/usr/bin/cpp"
  if [ -e "/lib/cpp" ]; then
    CPP_LINK="/lib/cpp"
  fi
  ${SUDO} update-alternatives --install "${CPP_LINK}" cpp "${CPP_BIN}" "${ALTS_PRIORITY}"
fi

if [ -x "${GCOV_BIN}" ]; then
  echo "Registering gcov..."
  ${SUDO} update-alternatives --install /usr/bin/gcov gcov "${GCOV_BIN}" "${ALTS_PRIORITY}"
fi

if [ -x "${GFORTRAN_BIN}" ]; then
  echo "Registering gfortran..."
  ${SUDO} update-alternatives --install /usr/bin/gfortran gfortran "${GFORTRAN_BIN}" "${ALTS_PRIORITY}"
fi

echo "Registering /usr/bin/cc to point to ${GCC_BIN}..."
${SUDO} update-alternatives --install /usr/bin/cc cc "${GCC_BIN}" "${ALTS_PRIORITY}"

echo "Setting alternatives (gcc + cc + optional tools)..."
${SUDO} update-alternatives --set gcc "${GCC_BIN}" || true
${SUDO} update-alternatives --set cc "${GCC_BIN}" || true
if [ -x "${GXX_BIN}" ]; then ${SUDO} update-alternatives --set g++ "${GXX_BIN}" || true; fi
if [ -x "${CPP_BIN}" ]; then ${SUDO} update-alternatives --set cpp "${CPP_BIN}" || true; fi
if [ -x "${GCOV_BIN}" ]; then ${SUDO} update-alternatives --set gcov "${GCOV_BIN}" || true; fi
if [ -x "${GFORTRAN_BIN}" ]; then ${SUDO} update-alternatives --set gfortran "${GFORTRAN_BIN}" || true; fi

echo "update-alternatives registration complete."

# 6) Add library path to loader and run ldconfig
CONF_FILE="/etc/ld.so.conf.d/gcc-${GCC_VERSION}.conf"

# sudo-safe: redirection can't be elevated, so use tee.
${SUDO} sh -c ": > \"${CONF_FILE}\""

if [ -d "${PREFIX}/lib64" ]; then
  echo "${PREFIX}/lib64" | ${SUDO} tee -a "${CONF_FILE}" >/dev/null
fi
if [ -d "${PREFIX}/lib" ]; then
  echo "${PREFIX}/lib" | ${SUDO} tee -a "${CONF_FILE}" >/dev/null
fi

if [ -s "${CONF_FILE}" ]; then
  echo "Adding GCC runtime libs from ${PREFIX} to loader path and running ldconfig..."
  ${SUDO} ldconfig
else
  ${SUDO} rm -f "${CONF_FILE}"
  echo "No GCC lib directories found under ${PREFIX}; skipping ldconfig step." >&2
fi

# 6b) Add pkg-config path configuration
echo "Configuring PKG_CONFIG_PATH..."
PKG_CONFIG_DIR="/etc/profile.d"
PKG_CONFIG_FILE="${PKG_CONFIG_DIR}/gcc-${GCC_VERSION}-pkgconfig.sh"

if [ -d "${PREFIX}/lib64/pkgconfig" ] || [ -d "${PREFIX}/lib/pkgconfig" ]; then
  ${SUDO} sh -c "cat > \"${PKG_CONFIG_FILE}\"" <<EOF
# GCC ${GCC_VERSION} pkg-config path
if [ -d "${PREFIX}/lib64/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${PREFIX}/lib64/pkgconfig:\${PKG_CONFIG_PATH}"
fi
if [ -d "${PREFIX}/lib/pkgconfig" ]; then
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:\${PKG_CONFIG_PATH}"
fi
EOF
  ${SUDO} chmod 644 "${PKG_CONFIG_FILE}"
  echo "Created ${PKG_CONFIG_FILE}"
else
  echo "No pkg-config directories found; skipping PKG_CONFIG_PATH setup."
fi

# 6c) Add to system PATH
echo "Configuring PATH..."
PATH_FILE="/etc/profile.d/gcc-${GCC_VERSION}-path.sh"
${SUDO} sh -c "cat > \"${PATH_FILE}\"" <<EOF
# GCC ${GCC_VERSION} binaries
export PATH="${PREFIX}/bin:\${PATH}"
EOF
${SUDO} chmod 644 "${PATH_FILE}"
echo "Created ${PATH_FILE}"

# 6c-docker) For Docker: Also add to /etc/environment for non-interactive shells
echo "Adding GCC paths to /etc/environment for Docker compatibility..."
if [ -f /etc/environment ]; then
  # Read current PATH from /etc/environment
  CURRENT_PATH=$(grep -E '^PATH=' /etc/environment 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
  if [ -z "$CURRENT_PATH" ]; then
    CURRENT_PATH="${PATH}"
  fi
  # Remove GCC prefix if already present to avoid duplicates
  CURRENT_PATH=$(echo "$CURRENT_PATH" | sed "s|${PREFIX}/bin:||g" | sed "s|:${PREFIX}/bin||g")
  # Prepend GCC bin directory
  NEW_PATH="${PREFIX}/bin:${CURRENT_PATH}"
  ${SUDO} sed -i '/^PATH=/d' /etc/environment 2>/dev/null || true
  echo "PATH=\"${NEW_PATH}\"" | ${SUDO} tee -a /etc/environment >/dev/null
  
  # Add PKG_CONFIG_PATH
  CURRENT_PKG=$(grep -E '^PKG_CONFIG_PATH=' /etc/environment 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
  NEW_PKG_PARTS=""
  if [ -d "${PREFIX}/lib64/pkgconfig" ]; then
    NEW_PKG_PARTS="${PREFIX}/lib64/pkgconfig"
  fi
  if [ -d "${PREFIX}/lib/pkgconfig" ]; then
    if [ -n "$NEW_PKG_PARTS" ]; then
      NEW_PKG_PARTS="${NEW_PKG_PARTS}:${PREFIX}/lib/pkgconfig"
    else
      NEW_PKG_PARTS="${PREFIX}/lib/pkgconfig"
    fi
  fi
  if [ -n "$NEW_PKG_PARTS" ]; then
    # Remove existing GCC pkgconfig paths to avoid duplicates
    CURRENT_PKG=$(echo "$CURRENT_PKG" | sed "s|${PREFIX}/lib64/pkgconfig:||g" | sed "s|:${PREFIX}/lib64/pkgconfig||g")
    CURRENT_PKG=$(echo "$CURRENT_PKG" | sed "s|${PREFIX}/lib/pkgconfig:||g" | sed "s|:${PREFIX}/lib/pkgconfig||g")
    if [ -n "$CURRENT_PKG" ]; then
      NEW_PKG="${NEW_PKG_PARTS}:${CURRENT_PKG}"
    else
      NEW_PKG="${NEW_PKG_PARTS}"
    fi
    ${SUDO} sed -i '/^PKG_CONFIG_PATH=/d' /etc/environment 2>/dev/null || true
    echo "PKG_CONFIG_PATH=\"${NEW_PKG}\"" | ${SUDO} tee -a /etc/environment >/dev/null
  fi
  
  # Add LD_LIBRARY_PATH
  CURRENT_LD=$(grep -E '^LD_LIBRARY_PATH=' /etc/environment 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "")
  NEW_LD_PARTS=""
  if [ -d "${PREFIX}/lib64" ]; then
    NEW_LD_PARTS="${PREFIX}/lib64"
  fi
  if [ -d "${PREFIX}/lib" ]; then
    if [ -n "$NEW_LD_PARTS" ]; then
      NEW_LD_PARTS="${NEW_LD_PARTS}:${PREFIX}/lib"
    else
      NEW_LD_PARTS="${PREFIX}/lib"
    fi
  fi
  if [ -n "$NEW_LD_PARTS" ]; then
    # Remove existing GCC lib paths to avoid duplicates
    CURRENT_LD=$(echo "$CURRENT_LD" | sed "s|${PREFIX}/lib64:||g" | sed "s|:${PREFIX}/lib64||g")
    CURRENT_LD=$(echo "$CURRENT_LD" | sed "s|${PREFIX}/lib:||g" | sed "s|:${PREFIX}/lib||g")
    if [ -n "$CURRENT_LD" ]; then
      NEW_LD="${NEW_LD_PARTS}:${CURRENT_LD}"
    else
      NEW_LD="${NEW_LD_PARTS}"
    fi
    ${SUDO} sed -i '/^LD_LIBRARY_PATH=/d' /etc/environment 2>/dev/null || true
    echo "LD_LIBRARY_PATH=\"${NEW_LD}\"" | ${SUDO} tee -a /etc/environment >/dev/null
  fi
  
  echo "Updated /etc/environment with GCC paths"
else
  echo "WARNING: /etc/environment not found; skipping Docker-friendly environment setup"
fi

# 6d) Configure man pages
echo "Configuring man pages..."
MANPATH_FILE="/etc/manpath.config"
if [ -d "${PREFIX}/share/man" ] && [ -f "${MANPATH_FILE}" ]; then
  if ! grep -q "${PREFIX}/share/man" "${MANPATH_FILE}" 2>/dev/null; then
    echo "MANPATH_MAP ${PREFIX}/bin ${PREFIX}/share/man" | ${SUDO} tee -a "${MANPATH_FILE}" >/dev/null
    echo "Added man page path to ${MANPATH_FILE}"
  else
    echo "Man page path already exists in ${MANPATH_FILE}"
  fi
elif [ -d "${PREFIX}/share/man" ]; then
  echo "MANPATH_FILE not found at ${MANPATH_FILE}; skipping man page configuration."
fi

# 7) Enhanced verification
echo
echo "============================================"
echo "=== Verification ==="
echo "============================================"
echo
echo "Active GCC location:"
which gcc || echo "ERROR: gcc not found in PATH"
echo
echo "Active GCC version:"
gcc --version 2>/dev/null | head -n1 || echo "ERROR: gcc --version failed"
echo
echo "Active G++ location:"
which g++ || echo "WARNING: g++ not found in PATH"
echo
echo "Active G++ version:"
g++ --version 2>/dev/null | head -n1 || echo "WARNING: g++ --version failed"
echo
echo "Active CC location:"
which cc || echo "WARNING: cc not found in PATH"
echo
echo "GCC alternative status:"
${SUDO} update-alternatives --display gcc 2>/dev/null | grep -E 'link currently points to|best version' || echo "WARNING: Could not query gcc alternative"
echo
echo "CC alternative status:"
${SUDO} update-alternatives --display cc 2>/dev/null | grep -E 'link currently points to|best version' || echo "WARNING: Could not query cc alternative"
echo
echo "Library search path (libstdc++ and libgcc):"
ldconfig -p 2>/dev/null | grep -E "libstdc\+\+|libgcc_s" | head -n10 || echo "WARNING: Could not query library paths"
echo
echo "Environment files created:"
ls -la /etc/profile.d/gcc-${GCC_VERSION}* 2>/dev/null || echo "No profile.d files found"
echo
echo "LD config file:"
ls -la /etc/ld.so.conf.d/gcc-${GCC_VERSION}.conf 2>/dev/null || echo "No ld.so.conf.d file found"
echo
echo "/etc/environment content (GCC-related lines):"
grep -E 'PATH|PKG_CONFIG_PATH|LD_LIBRARY_PATH' /etc/environment 2>/dev/null || echo "Could not read /etc/environment"
echo
echo "============================================"
echo "Installation complete!"
echo "============================================"
echo
echo "IMPORTANT: To activate the new GCC in your current shell, run:"
echo "  source /etc/profile.d/gcc-${GCC_VERSION}-path.sh"
echo "  source /etc/profile.d/gcc-${GCC_VERSION}-pkgconfig.sh"
echo
echo "Or for Docker/non-interactive shells, the paths are already in /etc/environment"
echo "and will be available in new shell sessions or after sourcing /etc/environment."
echo

# 8) Cleanup build artifacts to keep images smaller
echo
echo "Cleaning up build directory..."
if [ "${KEEP_BUILD}" = "1" ]; then
  echo "Keeping build directory (--keep-build): ${BUILD_DIR}"
elif [ -n "${BUILD_DIR}" ] && [ -d "${BUILD_DIR}" ]; then
  rm -rf "${BUILD_DIR}"
  echo "Removed: ${BUILD_DIR}"
fi

echo
echo "Done!"
