#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# Builds GCC from source (native, cross or Canadian cross); usage() lists the options.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/bootstrap.sh"
source_toolchain_common_or_fallback "${_SCRIPT_DIR}"
install_err_trap

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
  --compiler-cache                  Enable the compiler cache (sccache first, ccache fallback)
  --ccache                          DEPRECATED alias for --compiler-cache
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
  GCC_TARBALL_CACHE_DIR     Optional dir to reuse/store the release tarball
                            across builds (verification still runs each time;
                            unset = always download, unchanged behavior)
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
    --compiler-cache|--ccache)
      USE_CCACHE="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      warn "Unknown option: $1"; usage >&2; exit 1
      ;;
  esac
done

# GCC_VERSION_ENV is a legacy fallback when neither --version nor GCC_VERSION is set.
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
detect_system || echo "WARNING: detect_system failed; ARCH/HOST_ARCH/DISTRO may be unset (downstream steps may fail on unset vars)." >&2

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

# Compiler cache: a bootstrapped build caches only stage1; a Canadian cross prefixes the caller's CC/CXX.
if [ "${USE_CCACHE}" = "1" ]; then
  # The flag keeps its --ccache name for existing callers; it means sccache, with ccache as fallback.
  compiler_cache_launcher_env 2>/dev/null || true
  CC_LAUNCHER="$(compiler_cache_launcher || true)"
  if [ -n "${CC_LAUNCHER}" ]; then
    if [ -n "${HOST_TRIPLET}" ]; then
      export CC="${CC_LAUNCHER} ${CC:-${HOST_TRIPLET}-gcc}"
      export CXX="${CC_LAUNCHER} ${CXX:-${HOST_TRIPLET}-g++}"
    else
      export CC="${CC_LAUNCHER} gcc"
      export CXX="${CC_LAUNCHER} g++"
    fi
  fi

  # Keep per-target BUILD_DIRs out of the hash (SCCACHE_BASEDIRS needs sccache >= 0.14; Dockerfile.base stops cwd hashing).
  export CCACHE_BASEDIR="${BUILD_DIR}"
  export SCCACHE_BASEDIRS="${BUILD_DIR}"
  export CCACHE_SLOPPINESS="locale,time_macros,include_file_mtime,include_file_ctime"
  # Hash compiler content, not mtime: a rebuilt identical GCC would void every entry. sccache does not key on mtime.
  export CCACHE_COMPILERCHECK=content
fi

TARBALL="gcc-${GCC_VERSION}.tar.xz"
DOWNLOAD_BASE="https://gcc.gnu.org/pub/gcc/releases/gcc-${GCC_VERSION}"
# Tarball from the GNU mirror redirector first; checksum and signature stay canonical-only, so trust is unchanged.
MIRROR_BASE="https://ftpmirror.gnu.org/gnu/gcc/gcc-${GCC_VERSION}"
MIRROR_TARBALL_URL="${MIRROR_BASE}/${TARBALL}"
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

# 1) Build deps; GCC_SKIP_BUILD_DEPS=1 skips this for parallel targets, whose concurrent apt runs hit the dpkg lock.
if [ "${GCC_SKIP_BUILD_DEPS:-0}" != "1" ]; then
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
else
info "Skipping build dependencies (GCC_SKIP_BUILD_DEPS=1, installed by the host build)"
fi

# Tarballs ship generated parsers and docs, so no flex/bison/texinfo; overridable -w keeps the log actionable.
: "${CFLAGS:=-g -O2 -w}"
: "${CXXFLAGS:=-g -O2 -w}"
: "${FFLAGS:=-g -O2 -w}"
: "${FCFLAGS:=${FFLAGS}}"
: "${CFLAGS_FOR_BUILD:=${CFLAGS}}"
: "${CXXFLAGS_FOR_BUILD:=${CXXFLAGS}}"
: "${BOOT_CFLAGS:=-g -O2 -w}"
: "${STAGE1_CFLAGS:=${BOOT_CFLAGS}}"
export CFLAGS CXXFLAGS FFLAGS FCFLAGS CFLAGS_FOR_BUILD CXXFLAGS_FOR_BUILD BOOT_CFLAGS STAGE1_CFLAGS

# A no-op makeinfo: without texinfo the makefiles still probe for it and flood the log.
: "${MAKEINFO:=true}"
export MAKEINFO

# 2) Prepare build directory (no /tmp used)
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# A skipped GPG check warns, or is fatal under GCC_REQUIRE_GPG=1; a bad signature is always fatal.
_gcc_gpg_require_or_warn() {
  echo "WARNING: GPG signature verification was SKIPPED (no gpg or key unavailable); tarball is only SHA512-verified." >&2
  if [ "${GCC_REQUIRE_GPG:-0}" = "1" ]; then
    echo "ERROR: GCC_REQUIRE_GPG=1 — refusing to build without GPG verification." >&2
    exit 1
  fi
}

# Several release managers sign; a missing key (NO_PUBKEY) takes the skip path, a bad signature is fatal. GCC_GPG_KEYS overrides.
verify_gcc_gpg_signature() {
  # Fingerprints from https://gcc.gnu.org/mirrors.html ("release keys").
  local default_keys="D3A93CAD751C2AF4F8C7AD516C35B99309B5FA62 7F74F97C103468EE5D750B583AB00996FC26A641 33C235A34C46AA3FFB293709A328C3A2C3C45C06 13975A70E63C361C73AE69EF6EEB81F8981C74C7"
  local keys="${GCC_GPG_KEYS:-${default_keys}}"

  if ! _gcc_probe_url "${SIG_URL}"; then
    # Absent and unreachable look alike here, so obey GCC_REQUIRE_GPG.
    _gcc_gpg_require_or_warn
    return 0
  fi

  echo "Signature available at ${SIG_URL} (downloading)..."
  if ! wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SIG_URL}"; then
    echo "ERROR: signature exists on server but could not be downloaded; refusing to continue unverified." >&2
    exit 1
  fi

  if ! command -v gpg >/dev/null 2>&1; then
    echo "WARNING: gpg not installed." >&2
    _gcc_gpg_require_or_warn
    return 0
  fi

  echo "Attempting GPG verification..."
  # The script runs with IFS=$'\n\t', which would not split the space-separated fingerprints.
  local IFS=$' \t\n'
  local key
  for key in ${keys}; do
    gpg --list-keys "${key}" >/dev/null 2>&1 && continue
    echo "Importing GCC release signing key ${key}..."
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "${key}" 2>/dev/null || \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "${key}" 2>/dev/null || \
    echo "WARNING: could not import GCC release signing key ${key} from any keyserver." >&2
  done

  # gpg exits non-zero for a bad signature and a missing key alike; only the status lines differ.
  local status
  status="$(gpg --status-fd 1 --verify "${TARBALL}.sig" "${TARBALL}" 2>/dev/null || true)"

  if printf '%s\n' "${status}" | grep -q "^\[GNUPG:\] GOODSIG "; then
    # The signer (subkey or primary) must be an accepted key, not merely any imported one.
    local signer_fpr primary_fpr
    signer_fpr="$(printf '%s\n' "${status}" | awk '/^\[GNUPG:\] VALIDSIG /{print $3; exit}')"
    primary_fpr="$(printf '%s\n' "${status}" | awk '/^\[GNUPG:\] VALIDSIG /{print $NF; exit}')"
    case " ${keys} " in
      *" ${signer_fpr} "*|*" ${primary_fpr} "*)
        echo "GPG signature verified successfully (signer ${signer_fpr}, primary ${primary_fpr})."
        return 0
        ;;
    esac
    echo "ERROR: good signature, but signer ${signer_fpr:-unknown} (primary ${primary_fpr:-unknown}) is not an accepted GCC release key." >&2
    echo "If this is a legitimate new release manager, extend GCC_GPG_KEYS." >&2
    exit 1
  fi

  if printf '%s\n' "${status}" | grep -qE "^\[GNUPG:\] (NO_PUBKEY|ERRSIG) "; then
    # A missing signer key is no evidence either way: the skipped path, not tampering.
    local missing
    missing="$(printf '%s\n' "${status}" | awk '/^\[GNUPG:\] NO_PUBKEY /{print $3; exit}')"
    echo "WARNING: signature is by key ${missing:-unknown}, which could not be obtained." >&2
    echo "         If this is a new GCC release manager, add the fingerprint to GCC_GPG_KEYS." >&2
    _gcc_gpg_require_or_warn
    return 0
  fi

  echo "ERROR: GPG verification FAILED for ${TARBALL} (BADSIG/expired/revoked)." >&2
  echo "The tarball may be corrupted or tampered with. Aborting." >&2
  exit 1
}

# GCC_TARBALL_CACHE_DIR replaces only the download; the cached copy is still verified.
fetch_gcc_tarball() {
  if [ ! -f "${TARBALL}" ] && [ -n "${GCC_TARBALL_CACHE_DIR:-}" ] && [ -f "${GCC_TARBALL_CACHE_DIR}/${TARBALL}" ]; then
    echo "Reusing cached tarball: ${GCC_TARBALL_CACHE_DIR}/${TARBALL}"
    cp "${GCC_TARBALL_CACHE_DIR}/${TARBALL}" "${TARBALL}"
  fi
  if [ ! -f "${TARBALL}" ]; then
    # Mirror redirector first, canonical gcc.gnu.org as fallback.
    wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 3 "${MIRROR_TARBALL_URL}" -O "${TARBALL}" \
      || wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${TARBALL_URL}"
  else
    echo "Tarball already exists: ${TARBALL}"
  fi
}

# Explicit timeout for both proofs. docs/failure-modes.md#a-checksum-probe-that-cannot-reach-the-server-reads-as-nothing-to-verify
_gcc_probe_url() { wget -q --timeout=20 -t 3 --spider "$1"; }

_gcc_sha_unverified_or_die() {
  echo "WARNING: SHA512 verification did not happen: $1" >&2
  if [ "${GCC_ALLOW_UNVERIFIED_TARBALL:-0}" != "1" ]; then
    echo "ERROR: refusing to build an unverified GCC tarball. The bytes may come "\
         "from any GNU mirror; the proof comes only from gcc.gnu.org. Set "\
         "GCC_ALLOW_UNVERIFIED_TARBALL=1 to accept that trade deliberately." >&2
    exit 1
  fi
}

verify_gcc_sha512() {
  echo "Attempting SHA512 verification..."
  if ! _gcc_probe_url "${SHA_URL}"; then
    _gcc_sha_unverified_or_die "sha512.sum not reachable at ${SHA_URL} (absent, or the host did not answer)"
    return 0
  fi
  if ! wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SHA_URL}" -O sha512.sum; then
    echo "ERROR: sha512.sum exists on server but could not be downloaded; refusing to continue unverified." >&2
    exit 1
  fi
  if ! grep -Eq "[[:space:]]${TARBALL}\$" sha512.sum 2>/dev/null; then
    _gcc_sha_unverified_or_die "sha512.sum has no entry for ${TARBALL}"
    return 0
  fi
  grep -E "[[:space:]]${TARBALL}\$" sha512.sum > "${TARBALL}.sha512"
  if sha512sum -c --status "${TARBALL}.sha512"; then
    echo "SHA512 OK."
  else
    echo "ERROR: SHA512 mismatch - aborting." >&2
    exit 1
  fi
}

# Store the verified tarball via temp name and rename, so a concurrent reader never sees a partial file.
cache_store_gcc_tarball() {
  if [ -n "${GCC_TARBALL_CACHE_DIR:-}" ] && [ ! -f "${GCC_TARBALL_CACHE_DIR}/${TARBALL}" ]; then
    mkdir -p "${GCC_TARBALL_CACHE_DIR}"
    cp "${TARBALL}" "${GCC_TARBALL_CACHE_DIR}/${TARBALL}.tmp.$$"
    mv "${GCC_TARBALL_CACHE_DIR}/${TARBALL}.tmp.$$" "${GCC_TARBALL_CACHE_DIR}/${TARBALL}"
    echo "Stored tarball in cache: ${GCC_TARBALL_CACHE_DIR}/${TARBALL}"
  fi
}

echo "Downloading GCC sources to ${BUILD_DIR}..."
fetch_gcc_tarball
verify_gcc_sha512
verify_gcc_gpg_signature   # optional GPG check (defined above)
cache_store_gcc_tarball

# 3) Extract and configure
echo "Extracting ${TARBALL}..."
if [ ! -d "gcc-${GCC_VERSION}" ]; then
    tar -xf "${TARBALL}"
else
    echo "Source already extracted: gcc-${GCC_VERSION}"
fi
# PR100017: give src/c++23 the -nostdinc++ c++17 has. See docs/upstream-libstdcxx-c++23-nostdinc++.md § Root cause (one paragraph)
_c23_mkin="gcc-${GCC_VERSION}/libstdc++-v3/src/c++23/Makefile.in"
if [ -f "${_c23_mkin}" ] && ! grep -q -- '-nostdinc++' "${_c23_mkin}"; then
  sed -i 's|^\(\t*\)-std=gnu++23[[:space:]]*\\$|\1-std=gnu++23 -nostdinc++ \\|' "${_c23_mkin}"
  grep -q -- '-nostdinc++' "${_c23_mkin}" \
    || die "libstdc++ PR100017 fix FAILED: could not insert -nostdinc++ into ${_c23_mkin} (GCC ${GCC_VERSION} AM_CXXFLAGS layout changed -- update this patch)"
  echo "libstdc++: applied -nostdinc++ to src/c++23 (std module) Makefile.in [PR100017 parity with src/c++17]"
fi

rm -rf "gcc-${GCC_VERSION}-build"

# Canadian cross: build GMP/MPFR/MPC/ISL in-tree for the host arch, which has no -dev packages here.
if [ -n "${HOST_TRIPLET}" ]; then
  echo "Canadian cross: fetching in-tree GCC prerequisites (gmp/mpfr/mpc/isl)..."
  ( cd "gcc-${GCC_VERSION}" && ./contrib/download_prerequisites ) \
    || die "contrib/download_prerequisites failed; cannot build in-tree GMP/MPFR/MPC for Canadian cross host=${HOST_TRIPLET}"
fi

BUILD_SUBDIR="${BUILD_DIR}/gcc-${GCC_VERSION}-build"
mkdir -p "${BUILD_SUBDIR}"
cd "${BUILD_SUBDIR}"

# Pre-create the prefix: in-tree prerequisite configures cd into it and log a spurious error otherwise.
${SUDO} mkdir -p "${PREFIX}"

echo "Configuring build (languages: c,c++,fortran)..."
CONFIG_CMD=(
  "../gcc-${GCC_VERSION}/configure"
  "--prefix=${PREFIX}"
  "--enable-languages=${GCC_LANGUAGES}"
  "--disable-multilib"
  "--disable-fixed-point"
  "--enable-checking=release"
)

# A Canadian cross has no host zlib in the sysroot, so it takes GCC's bundled zlib instead of the system one.
if [ -z "${HOST_TRIPLET}" ]; then
  CONFIG_CMD+=("--with-system-zlib")
else
  echo "Canadian cross: using GCC in-tree zlib (no --with-system-zlib)."
fi

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

# host == target: the Canadian native, swapped in as the arm64/riscv64 image's cc.
_gcc_is_canadian_native() {
  if [ -n "${HOST_TRIPLET}" ] && [ "${HOST_TRIPLET}" = "${TARGET_TRIPLET}" ]; then return 0; fi
  return 1
}

# Explicit multiarch for the Canadian native. docs/cross-build-verification.md#the-native-gcc-has-multiarch
_gcc_native_multiarch() {
  if _gcc_is_canadian_native; then printf '%s' --enable-multiarch; fi
  return 0
}

if [ -n "${TARGET_TRIPLET}" ]; then
  _gcc_ma="$(_gcc_native_multiarch)"
  CONFIG_CMD+=(
    "--target=${TARGET_TRIPLET}"
    "--disable-nls"
    "--with-sysroot=${SYSROOT}"
    "--with-native-system-header-dir=${NATIVE_SYSTEM_HEADER_DIR}"
    ${_gcc_ma:+"${_gcc_ma}"}
  )
  # Pin an ISA spec the bundled binutils names, or the shipped riscv64 GCC's default -march will not assemble.
  case "${TARGET_TRIPLET}" in
    riscv64-*)
      _isa_spec="${RISCV_GCC_ISA_SPEC-20191213}"
      [ -n "${_isa_spec}" ] && CONFIG_CMD+=("--with-isa-spec=${_isa_spec}")
      # An ISA string, not the rva23u64 profile name, which GCC's configure rejects. docs/riscv64-rva23-baseline.md
      _rv_arch="${RISCV_GCC_ARCH-rv64gcv_zicsr_zifencei_zba_zbb_zbs_zicond}"
      _rv_abi="${RISCV_GCC_ABI-lp64d}"
      [ -n "${_rv_arch}" ] && CONFIG_CMD+=("--with-arch=${_rv_arch}")
      [ -n "${_rv_abi}" ] && CONFIG_CMD+=("--with-abi=${_rv_abi}")
      ;;
  esac
fi

# Canadian cross: GCC itself runs on the host triplet, whose cross compiler must be on PATH.
if [ -n "${HOST_TRIPLET}" ]; then
  BUILD_TRIPLET="$(gcc -dumpmachine 2>/dev/null || cc -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)"
  CONFIG_CMD+=("--build=${BUILD_TRIPLET}" "--host=${HOST_TRIPLET}")
  export CC="${CC:-${HOST_TRIPLET}-gcc}"
  export CXX="${CXX:-${HOST_TRIPLET}-g++}"
  # The Makefile runs bare ${HOST_TRIPLET}-* tools, so PATH gets the compiler word's dir (CC may carry a launcher).
  _cross_cc_word="${CC##* }"
  _cross_bin_dir="$(dirname "$(command -v "${_cross_cc_word}" 2>/dev/null || echo "${_cross_cc_word}")")"
  if [ -d "${_cross_bin_dir}" ]; then
    export PATH="${_cross_bin_dir}:${PATH}"
  fi
  # Pin the target compilers so target libgcc/libstdc++ use our cross compiler.
  export CC_FOR_TARGET="${CC_FOR_TARGET:-${CC}}"
  export CXX_FOR_TARGET="${CXX_FOR_TARGET:-${CXX}}"
  export GCC_FOR_TARGET="${GCC_FOR_TARGET:-${CC}}"
  export AR="${HOST_TRIPLET}-ar"
  export AS="${HOST_TRIPLET}-as"
  export LD="${HOST_TRIPLET}-ld"
  export RANLIB="${HOST_TRIPLET}-ranlib"
  export NM="${HOST_TRIPLET}-nm"
  export STRIP="${HOST_TRIPLET}-strip"
  export OBJCOPY="${HOST_TRIPLET}-objcopy"
  export OBJDUMP="${HOST_TRIPLET}-objdump"
  # Build-time host tools need the native (build-machine) compiler
  export CC_FOR_BUILD="${CC_FOR_BUILD:-gcc}"
  export CXX_FOR_BUILD="${CXX_FOR_BUILD:-g++}"
  # Force configure to accept the cross-compiler (Canadian cross host != build)
  export ac_cv_prog_cc_works=yes
  export ac_cv_prog_cxx_works=yes
  export gcc_cv_prog_cc_works=yes
fi

printf '%q ' "${CONFIG_CMD[@]}"; echo
trap - ERR
"${CONFIG_CMD[@]}" || {
  echo "=== configure failed. config.log tail: ===" >&2
  tail -60 config.log 2>/dev/null >&2 || true
  echo "=== end config.log ===" >&2
  exit 1
}
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

# 4) Build & install
echo "Building (this will take a long time)..."
# Zero cache stats once per RUN (the /tmp marker), so the hit rate aggregates over every GCC it builds.
if [ "${USE_CCACHE}" = "1" ] && [ ! -e /tmp/.gcc-cache-stats-zeroed ]; then
  ccache -z >/dev/null 2>&1 || true
  sccache --zero-stats >/dev/null 2>&1 || true
  : > /tmp/.gcc-cache-stats-zeroed 2>/dev/null || true
fi
# The Canadian native builds libsanitizer. docs/cross-build-verification.md#the-native-gcc-ships-libsanitizer
_gcc_extra_target_libs() {
  if _gcc_is_canadian_native; then printf '%s' target-libsanitizer; fi
  return 0
}
_gcc_san="$(_gcc_extra_target_libs)"
if [ -n "${TARGET_TRIPLET}" ]; then
  make -j"${JOBS}" all-gcc all-target-libgcc all-target-libstdc++-v3 all-target-libatomic ${_gcc_san:+"all-${_gcc_san}"}
else
  make -j"${JOBS}"
fi
# Cache stats for this compile phase, best effort; zero hits is the earliest sign of a dead cache.
if [ "${USE_CCACHE}" = "1" ]; then
  # Substring match: CC_LAUNCHER is a path such as .../sccache-launcher.sh.
  case "${CC_LAUNCHER:-}" in
    *sccache*) sccache --show-stats 2>/dev/null | grep -E '^(Compile requests|Cache hits|Cache misses|Non-cacheable|Unsupported|Errors)' || true ;;
    *)         ccache --show-stats 2>/dev/null | head -5 || true ;;
  esac
fi

echo "Installing to ${PREFIX}..."
${SUDO} mkdir -p "${PREFIX}"
if [ -n "${TARGET_TRIPLET}" ]; then
  ${SUDO} make install-gcc install-target-libgcc install-target-libstdc++-v3 install-target-libatomic ${_gcc_san:+"install-${_gcc_san}"} \
    2> >(filter_libtool_finish_warnings)
else
  ${SUDO} make install 2> >(filter_libtool_finish_warnings)
fi
# libsanitizer's configure can switch itself off silently (SANITIZER_SUPPORTED).
_gcc_assert_sanitizer_installed() {
  [ -f "${PREFIX}/lib/gcc/${TARGET_TRIPLET}/${GCC_VERSION}/include/sanitizer/common_interface_defs.h" ] \
    && compgen -G "${PREFIX}/lib*/libasan.so.*" >/dev/null \
    || die "libsanitizer installed no headers/libasan for ${TARGET_TRIPLET} under ${PREFIX}"
  return 0
}
[ -z "${_gcc_san}" ] || _gcc_assert_sanitizer_installed
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

  # alt_install_and_set registers each link and selects it, tolerating a failed --set.
  alt_install_and_set gcc /usr/bin/gcc "${GCC_BIN}" "${ALTS_PRIORITY}"
  if [ -x "${GXX_BIN}" ]; then alt_install_and_set g++ /usr/bin/g++ "${GXX_BIN}" "${ALTS_PRIORITY}"; fi

  if [ -x "${CPP_BIN}" ]; then
    CPP_LINK="/usr/bin/cpp"
    if [ -e "/lib/cpp" ]; then CPP_LINK="/lib/cpp"; fi
    alt_install_and_set cpp "${CPP_LINK}" "${CPP_BIN}" "${ALTS_PRIORITY}"
  fi

  if [ -x "${GCOV_BIN}" ]; then alt_install_and_set gcov /usr/bin/gcov "${GCOV_BIN}" "${ALTS_PRIORITY}"; fi
  if [ -x "${GFORTRAN_BIN}" ]; then alt_install_and_set gfortran /usr/bin/gfortran "${GFORTRAN_BIN}" "${ALTS_PRIORITY}"; fi

  alt_install_and_set cc /usr/bin/cc "${GCC_BIN}" "${ALTS_PRIORITY}"

  echo "update-alternatives registration complete."
fi

# 6e) Strip binaries if requested
if [ "${DO_STRIP}" = "1" ]; then
  info "Stripping binaries in ${PREFIX}..."
  # The build machine's strip too: the target's strip cannot read a plain cross compiler's x86-64 binaries.
  mapfile -t strip_files < <(${SUDO} find "${PREFIX}" -type f -executable -exec file {} + 2>/dev/null \
    | awk -F': *' '/ELF.*(executable|shared object)/{print $1}')
  for strip_bin in strip ${TARGET_TRIPLET:+"${TARGET_TRIPLET}-strip"}; do
    printf '%s\0' "${strip_files[@]}" | xargs -0 -r -P"${JOBS:-$(nproc)}" "${strip_bin}" --strip-all 2>/dev/null || true
  done
fi

# 7) Enhanced verification
if [ "${SKIP_SYSTEM_REGISTRATION}" != "1" ]; then
  # shellcheck disable=SC1091
  source "${_SCRIPT_DIR}/configure-gcc-env.sh"
  _configure_gcc_environment "${PREFIX}" "${GCC_VERSION}" "${SUDO}"

  # shellcheck disable=SC1091
  source "${_SCRIPT_DIR}/verify-gcc.sh"
  verify_gcc_installation "${PREFIX}" "${GCC_VERSION}" "${SUDO}"
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
