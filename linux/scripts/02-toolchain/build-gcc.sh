#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# build-gcc.sh
# Builds GCC from source and registers it as the system default via update-alternatives.
# Default build directory is $HOME/tmp2/gcc-build-<version> (no /tmp usage).
#
# Usage:
#   ./build-gcc.sh --version 16.1.0
#   ./build-gcc.sh --version 14.2.0 --prefix /opt/gcc-14 --jobs 8
#   GCC_VERSION=16.1.0 ./build-gcc.sh
#   GCC_VERSION=16.1.0 PREFIX=/opt/gcc-16 BUILD_DIR="$HOME/tmp2/mybuild" JOBS=4 ./build-gcc.sh

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/bootstrap.sh"
source_toolchain_common_or_fallback "${_SCRIPT_DIR}"

on_err() {
  local line="${1:-?}"
  local cmd="${2:-?}"
  err "Command failed (line ${line}): ${cmd}"
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

usage() {
  cat <<'USAGE'
Usage:
  ./build-gcc.sh --version <X.Y.Z> [options]
  ./build-gcc.sh -v <X.Y.Z> [options]

Options:
  --version, -v <version>   GCC version to build (required, e.g., 16.1.0, 14.2.0)
  --target <triplet>        Build a cross compiler for the target triplet
  --prefix <dir>            Install prefix (default: /opt/gcc-<version>)
  --build-dir <dir>         Build directory (default: $HOME/tmp2/gcc-build-<version>)
  --languages <list>        Languages to build (default: native=c,c++,fortran; cross=c,c++)
  --sysroot <dir>           Sysroot for cross builds (default: /)
  --native-system-header-dir <dir>
                            Native system header dir for cross builds (default: /usr/<triplet>/include)
  --jobs, -j <n>            Parallel jobs (auto-detected if not specified)
  --keep-build              Do not delete BUILD_DIR at the end
  --disable-bootstrap       Disable GCC bootstrap (default for cross builds)
  --skip-system-registration
                            Skip update-alternatives, loader, and profile updates
  --no-strip                Do not strip binaries after install
  --ccache                  Use ccache for faster rebuilds
  -h, --help                Show this help

Environment (used as defaults when CLI args are omitted):
  GCC_VERSION               GCC version to build
  TARGET_TRIPLET            GCC target triplet for cross builds
  PREFIX                    Install prefix
  BUILD_DIR                 Build directory
  GCC_LANGUAGES             Languages to build
  SYSROOT                   Sysroot for cross builds
  NATIVE_SYSTEM_HEADER_DIR  Native system header dir for cross builds
  JOBS                      Parallel jobs
  GCC_BUILD_MB_PER_JOB      Memory cap per job for parallel build (default: 2500)
USAGE
}

KEEP_BUILD="0"
DO_STRIP="1"
USE_CCACHE="0"
GCC_VERSION="${GCC_VERSION:-}"
TARGET_TRIPLET="${TARGET_TRIPLET:-}"
HOST_TRIPLET="${HOST_TRIPLET:-}"
GCC_LANGUAGES="${GCC_LANGUAGES:-}"
SYSROOT="${SYSROOT:-}"
NATIVE_SYSTEM_HEADER_DIR="${NATIVE_SYSTEM_HEADER_DIR:-}"
ENABLE_BOOTSTRAP="${ENABLE_BOOTSTRAP:-}"
SKIP_SYSTEM_REGISTRATION="${SKIP_SYSTEM_REGISTRATION:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|-v)
      GCC_VERSION="$2"
      shift 2
      ;;
    --target)
      TARGET_TRIPLET="$2"
      shift 2
      ;;
    --host)
      HOST_TRIPLET="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --build-dir)
      BUILD_DIR="$2"
      shift 2
      ;;
    --languages)
      GCC_LANGUAGES="$2"
      shift 2
      ;;
    --sysroot)
      SYSROOT="$2"
      shift 2
      ;;
    --native-system-header-dir)
      NATIVE_SYSTEM_HEADER_DIR="$2"
      shift 2
      ;;
    --jobs|-j)
      JOBS="$2"
      shift 2
      ;;
    --keep-build)
      KEEP_BUILD=1
      shift
      ;;
    --disable-bootstrap)
      ENABLE_BOOTSTRAP="0"
      shift
      ;;
    --skip-system-registration)
      SKIP_SYSTEM_REGISTRATION="1"
      shift
      ;;
    --no-strip)
      DO_STRIP="0"
      shift
      ;;
    --ccache)
      USE_CCACHE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Preserve GCC_VERSION from the environment and keep GCC_VERSION_ENV as a
# legacy fallback when the CLI does not provide --version.
GCC_VERSION="${GCC_VERSION:-${GCC_VERSION_ENV:-}}"
if [ -z "${GCC_VERSION}" ]; then
  die "GCC version is required. Use --version <X.Y.Z> or set GCC_VERSION environment variable."
fi

# Validate version format
if ! [[ "${GCC_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  warn "GCC_VERSION '${GCC_VERSION}' does not match expected format X.Y.Z (e.g., 16.1.0)"
fi

if [ -n "${HOST_TRIPLET}" ]; then
  # Canadian cross: building GCC to run on host arch, producing target arch code
  GCC_LANGUAGES="${GCC_LANGUAGES:-c,c++}"
  SYSROOT="${SYSROOT:-/}"
  NATIVE_SYSTEM_HEADER_DIR="${NATIVE_SYSTEM_HEADER_DIR:-/usr/${TARGET_TRIPLET}/include}"
  ENABLE_BOOTSTRAP="${ENABLE_BOOTSTRAP:-0}"
  SKIP_SYSTEM_REGISTRATION="${SKIP_SYSTEM_REGISTRATION:-1}"
elif [ -n "${TARGET_TRIPLET}" ]; then
  GCC_LANGUAGES="${GCC_LANGUAGES:-c,c++}"
  SYSROOT="${SYSROOT:-/}"
  NATIVE_SYSTEM_HEADER_DIR="${NATIVE_SYSTEM_HEADER_DIR:-/usr/${TARGET_TRIPLET}/include}"
  ENABLE_BOOTSTRAP="${ENABLE_BOOTSTRAP:-0}"
  SKIP_SYSTEM_REGISTRATION="${SKIP_SYSTEM_REGISTRATION:-1}"
else
  GCC_LANGUAGES="${GCC_LANGUAGES:-c,c++,fortran}"
  ENABLE_BOOTSTRAP="${ENABLE_BOOTSTRAP:-1}"
  SKIP_SYSTEM_REGISTRATION="${SKIP_SYSTEM_REGISTRATION:-0}"
fi

# DEFAULT: use a tmp2 directory in the user's home — avoids /tmp entirely
if [ -n "${HOST_TRIPLET}" ]; then
  BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${GCC_VERSION}-host-${HOST_TRIPLET}${TARGET_TRIPLET:+-target-${TARGET_TRIPLET}}}"
else
  BUILD_DIR="${BUILD_DIR:-${HOME}/tmp2/gcc-build-${GCC_VERSION}${TARGET_TRIPLET:+-${TARGET_TRIPLET}}}"
fi
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

if [ "${USE_CCACHE}" = "1" ] && [ -z "${HOST_TRIPLET}" ]; then
  if ! command -v ccache >/dev/null 2>&1; then
    warn "ccache not found, installing..."
    apt_install ccache
  fi
  CCACHE_DIR="${CCACHE_DIR:-${HOME}/.cache/ccache}"
  mkdir -p "${CCACHE_DIR}"
  export CCACHE_DIR
  export CC="ccache gcc"
  export CXX="ccache g++"
  info "Using ccache with CCACHE_DIR=${CCACHE_DIR}"
fi

TARBALL="gcc-${GCC_VERSION}.tar.xz"
DOWNLOAD_BASE="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VERSION}"
TARBALL_URL="${DOWNLOAD_BASE}/${TARBALL}"
SHA_URL="${DOWNLOAD_BASE}/sha512.sum"
SIG_URL="${DOWNLOAD_BASE}/${TARBALL}.sig"

if [ -n "${HOST_TRIPLET}" ]; then
  info "=== Build GCC ${GCC_VERSION} Canadian cross (host=${HOST_TRIPLET} target=${TARGET_TRIPLET}) ==="
elif [ -n "${TARGET_TRIPLET}" ]; then
  info "=== Build GCC ${GCC_VERSION} cross toolchain for ${TARGET_TRIPLET} ==="
else
  info "=== Build & set GCC ${GCC_VERSION} as system default ==="
fi
info "Prefix: ${PREFIX}"
info "Build dir: ${BUILD_DIR}"
info "Parallel jobs: ${JOBS}"
info "Languages: ${GCC_LANGUAGES}"
if [ -n "${TARGET_TRIPLET}" ]; then
  info "Target: ${TARGET_TRIPLET}"
  info "Sysroot: ${SYSROOT}"
  info "Native system headers: ${NATIVE_SYSTEM_HEADER_DIR}"
fi
if [ -n "${HOST_TRIPLET}" ]; then
  info "Host: ${HOST_TRIPLET}"
  info "CC=${CC:-${HOST_TRIPLET}-gcc}"
  info "CXX=${CXX:-${HOST_TRIPLET}-g++}"
fi
info "Bootstrap: ${ENABLE_BOOTSTRAP}"
info "System registration: ${SKIP_SYSTEM_REGISTRATION}"
info "Strip binaries: ${DO_STRIP:-1}"
if [ "${USE_CCACHE}" = "1" ]; then
  info "ccache: enabled"
fi
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
  python3 \
  libexpat1-dev \
  libncurses-dev \
  libelf-dev \
  patch \
  git \
  gnupg

# GCC release tarballs already ship generated parser/doc artifacts, so the
# build does not need flex, bison, or texinfo just to rebuild them.
# Default warning-suppression flags keep the toolchain build log focused on
# actionable failures while still allowing callers to override them.
: "${CFLAGS:=-g -O2 -w}"
: "${CXXFLAGS:=-g -O2 -w}"
: "${FFLAGS:=-g -O2 -w}"
: "${FCFLAGS:=${FFLAGS}}"
: "${CFLAGS_FOR_BUILD:=${CFLAGS}}"
: "${CXXFLAGS_FOR_BUILD:=${CXXFLAGS}}"
: "${BOOT_CFLAGS:=-g -O2 -w}"
: "${STAGE1_CFLAGS:=${BOOT_CFLAGS}}"
export CFLAGS CXXFLAGS FFLAGS FCFLAGS CFLAGS_FOR_BUILD CXXFLAGS_FOR_BUILD BOOT_CFLAGS STAGE1_CFLAGS

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
  if grep -Eq "[[:space:]]${TARBALL}\$" sha512.sum 2>/dev/null; then
    grep -E "[[:space:]]${TARBALL}\$" sha512.sum > "${TARBALL}.sha512"
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
  echo "Signature available at ${SIG_URL} (downloading)..."
  wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SIG_URL}" || true
  
  # GPG verification (GCC Release Signing Key)
  GCC_RELEASE_KEY="D3A93CAD751C2AF4F8C7AD516C35B99309B5FA62"
  echo "Attempting GPG verification..."
  if command -v gpg >/dev/null 2>&1; then
    # Import GCC release key if not present
    if ! gpg --list-keys "${GCC_RELEASE_KEY}" >/dev/null 2>&1; then
      echo "Importing GCC release signing key..."
      gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "${GCC_RELEASE_KEY}" 2>/dev/null || \
      gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "${GCC_RELEASE_KEY}" 2>/dev/null || \
      echo "Warning: Could not import GPG key, skipping signature verification"
    fi
    
    if gpg --list-keys "${GCC_RELEASE_KEY}" >/dev/null 2>&1; then
      if gpg --verify "${TARBALL}.sig" "${TARBALL}" 2>/dev/null; then
        echo "GPG signature verified successfully."
      else
        echo "WARNING: GPG verification FAILED. Proceeding with caution." >&2
      fi
    fi
  else
    echo "Warning: gpg not installed, skipping signature verification" >&2
  fi
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
  "--enable-languages=${GCC_LANGUAGES}"
  "--disable-multilib"
  "--disable-fixed-point"
  "--enable-checking=release"
  "--with-system-zlib"
)

filter_libtool_finish_warnings() {
  local line

  while IFS= read -r line; do
    case "${line}" in
      "libtool: install: warning: remember to run \`libtool --finish "*) continue ;;
    esac
    printf '%s\n' "${line}" >&2
  done
}

finish_libtool_dirs() {
  local libdir

  command -v libtool >/dev/null 2>&1 || return 0
  while IFS= read -r libdir; do
    [ -n "${libdir}" ] || continue
    ${SUDO} libtool --finish "${libdir}" >/dev/null 2>&1 || true
  done < <(find "${PREFIX}" -type f -name '*.la' -printf '%h\n' | sort -u)
}

if [ "${ENABLE_BOOTSTRAP}" = "1" ]; then
  CONFIG_CMD+=("--enable-bootstrap")
else
  CONFIG_CMD+=("--disable-bootstrap")
fi

if [ -n "${TARGET_TRIPLET}" ]; then
  CONFIG_CMD+=(
    "--target=${TARGET_TRIPLET}"
    "--disable-nls"
    "--with-sysroot=${SYSROOT}"
    "--with-native-system-header-dir=${NATIVE_SYSTEM_HEADER_DIR}"
  )
fi

# Canadian cross: GCC itself is cross-compiled to run on a different host. The
# resulting binaries are host-architecture executables that produce target-arch
# code. This requires the cross-compiler for the host triplet to be on PATH.
if [ -n "${HOST_TRIPLET}" ]; then
  CONFIG_CMD+=("--host=${HOST_TRIPLET}")
  export CC="${HOST_TRIPLET}-gcc"
  export CXX="${HOST_TRIPLET}-g++"
  export AR="${HOST_TRIPLET}-ar"
  export RANLIB="${HOST_TRIPLET}-ranlib"
  export NM="${HOST_TRIPLET}-nm"
  export STRIP="${HOST_TRIPLET}-strip"
  # Build-time host tools need the native (build-machine) compiler
  export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
  export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++}"
fi

printf '%q ' "${CONFIG_CMD[@]}"; echo
"${CONFIG_CMD[@]}"

# 4) Build & install
echo "Building (this will take a long time)..."
if [ -n "${TARGET_TRIPLET}" ]; then
  make -j"${JOBS}" all-gcc all-target-libgcc all-target-libstdc++-v3 all-target-libatomic
else
  make -j"${JOBS}"
fi

echo "Installing to ${PREFIX}..."
${SUDO} mkdir -p "${PREFIX}"
if [ -n "${TARGET_TRIPLET}" ]; then
  ${SUDO} make install-gcc install-target-libgcc install-target-libstdc++-v3 install-target-libatomic \
    2> >(filter_libtool_finish_warnings)
else
  ${SUDO} make install 2> >(filter_libtool_finish_warnings)
fi
finish_libtool_dirs

if [ "${SKIP_SYSTEM_REGISTRATION}" != "1" ]; then
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
fi

# 6e) Strip binaries if requested
if [ "${DO_STRIP}" = "1" ]; then
  info "Stripping binaries in ${PREFIX}..."
  if [ -n "${TARGET_TRIPLET}" ] && command -v "${TARGET_TRIPLET}-strip" >/dev/null 2>&1; then
    ${SUDO} find "${PREFIX}" -type f -executable -exec sh -c 'file "$1" | grep -qE "ELF.*executable|ELF.*shared object" && "${0}" --strip-all "$1"' "${TARGET_TRIPLET}-strip" {} \; 2>/dev/null || true
  else
    ${SUDO} find "${PREFIX}" -type f -executable -exec sh -c 'file "$1" | grep -qE "ELF.*executable|ELF.*shared object" && strip --strip-all "$1"' _ {} \; 2>/dev/null || true
  fi
fi

if [ "${SKIP_SYSTEM_REGISTRATION}" != "1" ]; then
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
else
  echo
  echo "============================================"
  echo "=== Cross Compiler Verification ==="
  echo "============================================"
  echo
  if [ -n "${TARGET_TRIPLET}" ]; then
    if [ -x "${PREFIX}/bin/${TARGET_TRIPLET}-gcc" ]; then
      echo "Installed cross GCC:"
      "${PREFIX}/bin/${TARGET_TRIPLET}-gcc" --version 2>/dev/null | head -n1 || true
      echo
    fi
    if [ -x "${PREFIX}/bin/${TARGET_TRIPLET}-g++" ]; then
      echo "Installed cross G++:"
      "${PREFIX}/bin/${TARGET_TRIPLET}-g++" --version 2>/dev/null | head -n1 || true
      echo
    fi
  fi
  echo "Skipped system registration for this targeted install."
  echo
fi

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
