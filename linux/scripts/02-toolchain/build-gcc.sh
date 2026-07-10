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
    --ccache)
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

if [ "${USE_CCACHE}" = "1" ] && [ -z "${HOST_TRIPLET}" ]; then
  ensure_ccache_env
  export CC="ccache gcc"
  export CXX="ccache g++"
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

# Emit the "GPG was skipped" warning and honor the GCC_REQUIRE_GPG policy: a
# skipped verification (no gpg, or the release key was unreachable — common in
# sandboxed build networks) is a loud warning by default, fatal when
# GCC_REQUIRE_GPG=1. A failed VERIFY with the key present is handled separately
# (always fatal) in verify_gcc_gpg_signature.
_gcc_gpg_require_or_warn() {
  echo "WARNING: GPG signature verification was SKIPPED (no gpg or key unavailable); tarball is only SHA512-verified." >&2
  if [ "${GCC_REQUIRE_GPG:-0}" = "1" ]; then
    echo "ERROR: GCC_REQUIRE_GPG=1 — refusing to build without GPG verification." >&2
    exit 1
  fi
}

# Optional GPG verification of the downloaded GCC tarball against the GCC Release
# Signing Key. Flattened from a 5-level nested pyramid into guard clauses; the
# policy is unchanged: no .sig on server → skip cleanly; .sig present but
# undownloadable → fatal; verify FAILS with key present → fatal; otherwise
# (no gpg / key unavailable) → _gcc_gpg_require_or_warn.
verify_gcc_gpg_signature() {
  local key="D3A93CAD751C2AF4F8C7AD516C35B99309B5FA62"  # GCC Release Signing Key

  if ! wget -q --spider "${SIG_URL}"; then
    echo "No .sig found or accessible."
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
  if ! gpg --list-keys "${key}" >/dev/null 2>&1; then
    echo "Importing GCC release signing key..."
    gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "${key}" 2>/dev/null || \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "${key}" 2>/dev/null || \
    echo "WARNING: could not import the GCC release signing key from any keyserver." >&2
  fi

  # Key still unavailable → cannot verify; treat as skipped, not failed.
  if ! gpg --list-keys "${key}" >/dev/null 2>&1; then
    _gcc_gpg_require_or_warn
    return 0
  fi

  if gpg --verify "${TARBALL}.sig" "${TARBALL}" 2>/dev/null; then
    echo "GPG signature verified successfully."
    return 0
  fi
  echo "ERROR: GPG verification FAILED for ${TARBALL}." >&2
  echo "The tarball may be corrupted or tampered with. Aborting." >&2
  exit 1
}

# Fetch the GCC tarball into ${BUILD_DIR}. Opt-in tarball cache: when
# GCC_TARBALL_CACHE_DIR is set (e.g. by gcc.sh's multi-target orchestration),
# reuse a previously downloaded tarball instead of re-downloading into every
# per-target BUILD_DIR. The reused copy still goes through the exact same
# SHA512/GPG verification below — the cache only replaces the network fetch,
# never the verification. Inert (behavior unchanged) when the variable is unset.
fetch_gcc_tarball() {
  if [ ! -f "${TARBALL}" ] && [ -n "${GCC_TARBALL_CACHE_DIR:-}" ] && [ -f "${GCC_TARBALL_CACHE_DIR}/${TARBALL}" ]; then
    echo "Reusing cached tarball: ${GCC_TARBALL_CACHE_DIR}/${TARBALL}"
    cp "${GCC_TARBALL_CACHE_DIR}/${TARBALL}" "${TARBALL}"
  fi
  if [ ! -f "${TARBALL}" ]; then
    wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${TARBALL_URL}"
  else
    echo "Tarball already exists: ${TARBALL}"
  fi
}

# Verify the tarball against the server's sha512.sum. If the server has a
# checksum file, failing to fetch or match it aborts (no silent downgrade to an
# unverified build); a missing checksum file is only a warning.
verify_gcc_sha512() {
  echo "Attempting SHA512 verification..."
  if ! wget -q --spider "${SHA_URL}"; then
    echo "No sha512.sum found on server; continuing." >&2
    return 0
  fi
  if ! wget -c --https-only --retry-connrefused --waitretry=1 --read-timeout=20 --timeout=20 -t 5 "${SHA_URL}" -O sha512.sum; then
    echo "ERROR: sha512.sum exists on server but could not be downloaded; refusing to continue unverified." >&2
    exit 1
  fi
  if ! grep -Eq "[[:space:]]${TARBALL}\$" sha512.sum 2>/dev/null; then
    echo "WARNING: tarball entry not found in sha512.sum; continuing without SHA check." >&2
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

# Opt-in tarball cache: store the verified tarball for reuse by later targets.
# Inert when GCC_TARBALL_CACHE_DIR is unset. Copies via a temp name + rename so a
# concurrent reader never sees a partially written cache entry.
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
# libstdc++ Canadian-cross fix (GCC PR100017 / PR101060), scoped to the C++23
# MODULE directory upstream forgot to propagate it to.
#
# src/c++17/Makefile.am carries `-nostdinc++` in AM_CXXFLAGS precisely so the
# TARGET libstdc++ build cannot pull in the *host* compiler's libstdc++ headers.
# src/c++23 (which builds the `std`/`std.compat` modules from std.cc) is MISSING
# it. In a Canadian cross (host != build) the host g++ headers are on the search
# path; `#include <cfenv>` -> the target `<fenv.h>` wrapper -> `#include_next
# <fenv.h>` then finds the *host* libstdc++ `<fenv.h>` wrapper, which shares the
# guard `_GLIBCXX_FENV_H` with the target wrapper and is therefore guard-skipped,
# so the underlying libc <fenv.h> is NEVER reached. Result: `::fenv_t` (and every
# fe* symbol) is undeclared -> `error: 'fenv_t' has not been declared in '::'`,
# the std.cc compile fails, and libstdc++'s recipe silently ships an EMPTY module
# (stamp-modules-bits "Error 1 (ignored)").  The target sysroot's <fenv.h> is
# fine; the header is simply never included.  Fix = mirror the c++17 flag into the
# c++23 module dir.  Patch the shipped Makefile.in (release tarballs pre-generate
# it; maintainer-mode is off so touching Makefile.in won't trigger a regen).
_c23_mkin="gcc-${GCC_VERSION}/libstdc++-v3/src/c++23/Makefile.in"
if [ -f "${_c23_mkin}" ] && ! grep -q -- '-nostdinc++' "${_c23_mkin}"; then
  sed -i 's|^\(\t*\)-std=gnu++23[[:space:]]*\\$|\1-std=gnu++23 -nostdinc++ \\|' "${_c23_mkin}"
  grep -q -- '-nostdinc++' "${_c23_mkin}" \
    || die "libstdc++ PR100017 fix FAILED: could not insert -nostdinc++ into ${_c23_mkin} (GCC ${GCC_VERSION} AM_CXXFLAGS layout changed -- update this patch)"
  echo "libstdc++: applied -nostdinc++ to src/c++23 (std module) Makefile.in [PR100017 parity with src/c++17]"
fi

rm -rf "gcc-${GCC_VERSION}-build"

# Canadian cross (host != build): GCC's binaries run on the *host* arch and link
# against GMP/MPFR/MPC/ISL. The build host only has build-arch (amd64) -dev
# packages, so configure fails with "correct version of gmp.h... no". Pull the
# math libraries into the GCC source tree so configure builds them in-tree,
# cross-compiled for the host arch. (Plain target cross builds keep build==host
# == amd64 and can use the system libgmp-dev, so this is scoped to Canadian
# cross to avoid lengthening the host/target GCC builds.)
if [ -n "${HOST_TRIPLET}" ]; then
  echo "Canadian cross: fetching in-tree GCC prerequisites (gmp/mpfr/mpc/isl)..."
  ( cd "gcc-${GCC_VERSION}" && ./contrib/download_prerequisites ) \
    || die "contrib/download_prerequisites failed; cannot build in-tree GMP/MPFR/MPC for Canadian cross host=${HOST_TRIPLET}"
fi

BUILD_SUBDIR="${BUILD_DIR}/gcc-${GCC_VERSION}-build"
mkdir -p "${BUILD_SUBDIR}"
cd "${BUILD_SUBDIR}"

# Pre-create the install prefix BEFORE configure. GCC's in-tree prerequisite
# configures (isl in particular) resolve/cd into the eventual --prefix while
# probing; when it does not exist yet they print a spurious
# "cd: ${PREFIX}: No such file or directory" to stderr. It is harmless (the dir
# is also created at install time below) but reads as an error in the toolchain
# build log. Creating it up front keeps the log clean. Idempotent; mirrors the
# install-time mkdir and uses ${SUDO} for the same non-root-host case.
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

# --with-system-zlib makes GCC link its LTO support against the *host* system
# zlib. For a Canadian cross (host==target!=build) the host is the foreign arch
# and no host zlib lives in the cross sysroot, so the GCC build fails with
# "zlib.h: No such file or directory" while compiling lto-compress.cc. Fall back
# to GCC's bundled in-tree zlib (the zlib/ subdir of the release tarball), which
# configure builds cross-compiled for the host. Native and plain-target cross
# builds keep build==amd64 and use the faster system zlib.
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

if [ -n "${TARGET_TRIPLET}" ]; then
  CONFIG_CMD+=(
    "--target=${TARGET_TRIPLET}"
    "--disable-nls"
    "--with-sysroot=${SYSROOT}"
    "--with-native-system-header-dir=${NATIVE_SYSTEM_HEADER_DIR}"
  )
  # riscv64 (A2): GCC 16 defaults to the newer RISC-V ISA spec, whose canonical
  # -march expansion uses profile extension names (zmmul/zaamo/zalrsc/zca/zcd)
  # that an older binutils `as` rejects with "invalid -march= option". The build
  # itself is unaffected (it drives the assembler explicitly), but the SHIPPED
  # native riscv64 GCC then cannot assemble its own default output on-device.
  # Pin the ISA spec the bundled assembler understands so the default -march
  # stays assembler-compatible; this changes only the march NAMING, not codegen
  # (same ISA). Override with RISCV_GCC_ISA_SPEC=<spec>, or RISCV_GCC_ISA_SPEC=
  # (empty) to disable. NOTE: validated by shellcheck only in-repo; confirm with
  # a real riscv64 GCC rebuild (an on-device `gcc hello.c` must assemble).
  case "${TARGET_TRIPLET}" in
    riscv64-*)
      _isa_spec="${RISCV_GCC_ISA_SPEC-20191213}"
      [ -n "${_isa_spec}" ] && CONFIG_CMD+=("--with-isa-spec=${_isa_spec}")
      ;;
  esac
fi

# Canadian cross: GCC itself is cross-compiled to run on a different host. The
# resulting binaries are host-architecture executables that produce target-arch
# code. This requires the cross-compiler for the host triplet to be on PATH.
if [ -n "${HOST_TRIPLET}" ]; then
  BUILD_TRIPLET="$(gcc -dumpmachine 2>/dev/null || cc -dumpmachine 2>/dev/null || echo x86_64-pc-linux-gnu)"
  CONFIG_CMD+=("--build=${BUILD_TRIPLET}" "--host=${HOST_TRIPLET}")
  export CC="${CC:-${HOST_TRIPLET}-gcc}"
  export CXX="${CXX:-${HOST_TRIPLET}-g++}"
  # The cross compiler (and its triplet-prefixed binutils) live in a non-default
  # prefix such as /opt/gcc-<ver>/bin which is only added to /etc/profile.d (not
  # sourced by this non-login build subprocess). The GCC Makefile drives several
  # steps via the *bare* program names (GCC_FOR_TARGET=${HOST_TRIPLET}-gcc, the
  # `specs` target, AS/LD lookups), so without this the build dies with
  # "${HOST_TRIPLET}-gcc: command not found" (make Error 127). Put the cross
  # toolchain bin dir on PATH so every bare ${HOST_TRIPLET}-* tool resolves.
  _cross_bin_dir="$(dirname "$(command -v "${CC}" 2>/dev/null || echo "${CC}")")"
  if [ -d "${_cross_bin_dir}" ]; then
    export PATH="${_cross_bin_dir}:${PATH}"
  fi
  # Pin the build->target compilers explicitly so target libgcc/libstdc++ are
  # built with our cross compiler regardless of make's default lookup.
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

  # alt_install_and_set (01-core/common.sh) registers each link and immediately
  # --sets it (the --set is tolerant, matching the previous _set_alt || true).
  # ALTS_PRIORITY=150 is passed explicitly to preserve the historical priority.
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
  STRIP_BIN="strip"
  if [ -n "${TARGET_TRIPLET}" ] && command -v "${TARGET_TRIPLET}-strip" >/dev/null 2>&1; then
    STRIP_BIN="${TARGET_TRIPLET}-strip"
  fi
  strip_jobs="${JOBS:-$(nproc)}"
  ${SUDO} find "${PREFIX}" -type f -executable -exec file {} + 2>/dev/null \
    | awk -F': *' '/ELF.*(executable|shared object)/{print $1}' \
    | xargs -r -P"${strip_jobs}" "${STRIP_BIN}" --strip-all 2>/dev/null || true
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
