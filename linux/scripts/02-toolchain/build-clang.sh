#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022
# CCACHE-CONTENT (2026-08-19): survive compiler rebuilds (see build-gcc.sh note)
export CCACHE_COMPILERCHECK=content

# build-clang.sh
# Build LLVM/Clang from source for any architecture (RISC-V, ARM64, x86_64, etc.)
# Usage: build-clang.sh --version 22 [options]

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${_SCRIPT_DIR}/bootstrap.sh"
source_toolchain_common_or_fallback "${_SCRIPT_DIR}"
source_toolchain_build_helpers_or_fallback "${_SCRIPT_DIR}"
install_err_trap

usage() {
  cat <<'USAGE'
Usage: build-clang.sh --version <N> [options]

Build LLVM/Clang from source for any architecture.

Options:
  --version N       LLVM/Clang major version (required, e.g., 21, 22)
  --release X.Y.Z   LLVM release version (optional, auto-detected if not specified)
  --prefix DIR      Install prefix (default: /usr/local/llvm-<version>)
  --tag TAG         Git tag to use (optional, overrides --release)
  --bootstrap       Enable bootstrap build (default for non-RISC-V)
  --no-bootstrap    Disable bootstrap build (default for RISC-V)
  --lto             Enable LTO ( ThinLTO for Release builds)
  --no-strip        Do not strip binaries after install
  --keep-src        Keep source directory after build
  --keep-build      Keep build directory after install
  --jobs N          Number of parallel jobs (auto-detected if not specified)
  --targets LIST    LLVM targets to build (default: native; e.g., "RISCV;X86;AArch64")
  --ccache          Use ccache for faster rebuilds
  -h, --help        Show this help message

Examples:
  build-clang.sh --version 22
  build-clang.sh --version 21 --release 21.1.8 --prefix /opt/llvm-21
  build-clang.sh --version 22 --no-bootstrap --jobs 4
  build-clang.sh --version 22 --targets "RISCV;X86;AArch64"

USAGE
}

# --- Default Values ---
LLVM_VERSION=""
LLVM_RELEASE="${LLVM_RELEASE:-}"
LLVM_TAG=""
PREFIX=""
ARCH="$(uname -m)"
NUM_JOBS=""
LLVM_TARGETS=""

if [ "$ARCH" = "riscv64" ]; then
    BOOTSTRAP="OFF"
    info "RISC-V detected: Defaulting to NO-BOOTSTRAP to save time."
else
    BOOTSTRAP="ON"
fi

DO_STRIP="1"
KEEP_SRC="0"
KEEP_BUILD="0"
USE_CCACHE="0"
ENABLE_LTO="OFF"

# Parse options
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            LLVM_VERSION="$2"; shift 2 ;;
        --release)
            LLVM_RELEASE="$2"; shift 2 ;;
        --prefix)
            PREFIX="$2"; shift 2 ;;
        --tag)
            LLVM_TAG="$2"; shift 2 ;;
        --no-bootstrap)
            BOOTSTRAP="OFF"; shift ;;
        --bootstrap)
            BOOTSTRAP="ON"; shift ;;
        --lto)
            ENABLE_LTO="Thin"; shift ;;
        --no-strip)
            DO_STRIP="0"; shift ;;
        --keep-src)
            KEEP_SRC="1"; shift ;;
        --keep-build)
            KEEP_BUILD="1"; shift ;;
        --targets)
            LLVM_TARGETS="$2"; shift 2 ;;
        --ccache)
            USE_CCACHE="1"; shift ;;
        --jobs|-j)
            if [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                NUM_JOBS="$2"
                shift 2
            else
                die "--jobs requires a numeric argument"
            fi
            ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            warn "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

# --- Validate and compute values ---
if [ -z "${LLVM_VERSION:-}" ]; then
    die "Missing required option: --version (e.g., --version 22)"
fi

if [ -z "${LLVM_TARGETS:-}" ]; then
    case "$ARCH" in
        x86_64|amd64)    LLVM_TARGETS="X86" ;;
        aarch64|arm64)   LLVM_TARGETS="AArch64" ;;
        riscv64|riscv32) LLVM_TARGETS="RISCV" ;;
        arm*)            LLVM_TARGETS="ARM" ;;
        *)               LLVM_TARGETS="Native" ;;
    esac
fi

if [ "$USE_CCACHE" = "1" ]; then
    ensure_ccache_env
fi

# Compute release version and tag if not specified
LLVM_RELEASE="${LLVM_RELEASE:-$(llvm_release_version "${LLVM_VERSION}")}"
LLVM_TAG="${LLVM_TAG:-$(llvm_git_tag "${LLVM_VERSION}")}"

# Set default prefix if not specified
if [ -z "${PREFIX:-}" ]; then
    PREFIX="/usr/local/llvm-${LLVM_VERSION}"
fi

info "Building LLVM/Clang ${LLVM_VERSION} (${LLVM_TAG})"
info "Install prefix: ${PREFIX}"
info "Target arch: LLVM_TARGETS=${LLVM_TARGETS}"
info "LTO: ${ENABLE_LTO}, Assertions: OFF, Bootstrap: ${BOOTSTRAP}"

# --- Initialization & WORKDIR FIX ---
WD="$(pwd)"
# LLVM_CROSS_SOURCE_ROOT: honored so the Dockerfile's /var/cache/llvm-src cache
# mount actually backs this build's clone. Previously only llvm-cross.sh read
# it — this RUN cloned ~2 GB into a throwaway dir while the mount sat empty,
# and the target-clang RUN paid the same clone again.
DEFAULT_LLVM_WORK_ROOT="${LLVM_BUILD_ROOT:-${LLVM_CROSS_SOURCE_ROOT:-${HOME}/tmp2/llvm-build-root}}"
AUTO_WORKDIR="${DEFAULT_LLVM_WORK_ROOT}/llvm-work"

if [ "${WD}" = "/" ]; then
    warn "Detected execution from Root (/). Creating safe workspace in ${AUTO_WORKDIR}..."
    mkdir -p "${AUTO_WORKDIR}"
    cd "${AUTO_WORKDIR}"
    WD="${AUTO_WORKDIR}"
fi

SRC_DIR="${WD}/llvm-project"
BUILD_DIR="${WD}/llvm-build"
INSTALL_DIR="${PREFIX}"

require_sudo
detect_system || echo "WARNING: detect_system failed; ARCH/HOST_ARCH/DISTRO may be unset (downstream steps may fail on unset vars)." >&2

# ====== Preflight Checks ======
run_preflight_checks() {
    info "---- preflight: workdir safety ----"
    [ -n "${WD:-}" ] && [ "${WD}" != "/" ] || die "Unsafe WD: '${WD:-<empty>}' (should have been fixed)"

    info "---- preflight: tools ----"
    for t in git cmake ninja python3 file strip; do
        command -v "${t}" >/dev/null 2>&1 || die "Missing tool: ${t}"
    done

    info "---- preflight: disk space ----"
    local avail_mb
    avail_mb=$(df --output=avail -m "${WD}" 2>/dev/null | tail -n1 || echo 0)
    if [ "${avail_mb}" -lt 15000 ]; then
        warn "Low disk: ${avail_mb}MB"
    fi
}

# --- DYNAMIC JOB CALCULATION ---
if [ -n "${NUM_JOBS:-}" ] && [[ "${NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    : # Explicitly set by user, respect it.
elif [ -n "${CLANG_NUM_JOBS:-}" ] && [[ "${CLANG_NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    NUM_JOBS="${CLANG_NUM_JOBS}"
elif command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
    NUM_JOBS="$(compute_jobs_with_mem_cap "" "${CLANG_BUILD_MB_PER_JOB:-2000}")"
else
    NUM_JOBS="$(nproc || echo 1)"
fi
info "Using NUM_JOBS=${NUM_JOBS}"

info "Installing dependencies..."
apt_install build-essential git cmake ninja-build python3 libedit-dev \
    libncurses5-dev zlib1g-dev libxml2-dev libssl-dev pkg-config \
    libffi-dev curl ca-certificates file binutils binutils-dev ccache

if apt_has_package lld && apt_install lld; then
    info "LLD installed successfully."
    HAS_LLD=1
else
    warn "LLD package not found or failed to install. Will fallback to Gold/BFD."
    HAS_LLD=0
fi

run_preflight_checks

if [[ ! -d "${SRC_DIR}" ]]; then
    info "Fetching llvm-project ${LLVM_TAG}..."
    git init -q "${SRC_DIR}"
    git -C "${SRC_DIR}" remote add origin https://github.com/llvm/llvm-project.git
    git -C "${SRC_DIR}" fetch --depth 1 origin tag "${LLVM_TAG}"
    git -C "${SRC_DIR}" checkout -q FETCH_HEAD
    rm -rf "${BUILD_DIR}"  # fresh source = fresh build
elif [ ! -f "${BUILD_DIR}/CMakeCache.txt" ] || [ "${FORCE_REBUILD:-0}" = "1" ]; then
    rm -rf "${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ "$(uname -m)" = "riscv64" ]; then
    LINKER_FLAG=""
else
    if [ "$HAS_LLD" = "1" ]; then
        LINKER_FLAG="-DLLVM_USE_LINKER=lld"
    elif command -v ld.gold >/dev/null 2>&1; then
        LINKER_FLAG="-DLLVM_USE_LINKER=gold"
    else
        LINKER_FLAG=""
    fi
fi

if [ -z "${CC:-}" ]; then
    if command -v gcc >/dev/null 2>&1; then export CC=gcc; fi
    if command -v g++ >/dev/null 2>&1; then export CXX=g++; fi
fi

CMAKE_FLAGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"
    -DLLVM_ENABLE_RUNTIMES="compiler-rt"
    -DLLVM_TARGETS_TO_BUILD="${LLVM_TARGETS}"
    -DLLVM_ENABLE_LTO=${ENABLE_LTO}
    -DLLVM_ENABLE_ASSERTIONS=OFF
    -DLLVM_ENABLE_WARNINGS=OFF
    -DCLANG_ENABLE_BOOTSTRAP=${BOOTSTRAP}
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DCLANG_INCLUDE_TESTS=OFF
)

if [ -n "${LINKER_FLAG}" ]; then
    CMAKE_FLAGS+=("${LINKER_FLAG}")
fi

if [ "$USE_CCACHE" = "1" ]; then
    # Let CMake call the real compiler directly and inject ccache as a launcher.
    # Exporting CC="ccache gcc" makes CMake generate broken ASM rules for .S files.
    CMAKE_FLAGS+=(
        -DCMAKE_C_COMPILER_LAUNCHER=ccache
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    )
fi

echo "==> Configuring: LTO=${ENABLE_LTO}, Bootstrap=${BOOTSTRAP}, Targets=${LLVM_TARGETS}"
cmake "${CMAKE_FLAGS[@]}" "${SRC_DIR}/llvm"

echo "==> Building..."
if [[ "${BOOTSTRAP}" == "ON" ]]; then
    cmake --build . --target stage2 --parallel "${NUM_JOBS}"
else
    cmake --build . --parallel "${NUM_JOBS}"
fi

echo "==> Installing..."
${SUDO} cmake --build . --target install

echo "==> Setting system defaults..."
BIN_DIR="${INSTALL_DIR}/bin"
alt_install_and_set clang /usr/bin/clang "${BIN_DIR}/clang" 200 \
    --slave /usr/bin/clang++ clang++ "${BIN_DIR}/clang++" \
    --slave /usr/bin/clang-format clang-format "${BIN_DIR}/clang-format" \
    --slave /usr/bin/clang-tidy clang-tidy "${BIN_DIR}/clang-tidy" \
    --slave /usr/bin/clangd clangd "${BIN_DIR}/clangd" \
    --slave /usr/bin/ld.lld ld.lld "${BIN_DIR}/ld.lld"

# Keep the rest of the LLVM toolchain visible on PATH when apt.llvm.org is not
# available and this script becomes the primary installation path.
if [ -d "${BIN_DIR}" ]; then
    for tool_path in "${BIN_DIR}"/*; do
        [ -x "${tool_path}" ] || continue
        ${SUDO} ln -sf "${tool_path}" "/usr/local/bin/$(basename "${tool_path}")"
    done
fi

if [[ "${DO_STRIP}" == "1" ]]; then
    info "Stripping binaries..."
    strip_elf_tree "${INSTALL_DIR}" "${NUM_JOBS:-$(nproc)}"
fi

[[ "${KEEP_SRC}" != "1" ]] && rm -rf "${SRC_DIR}"
[[ "${KEEP_BUILD}" != "1" ]] && rm -rf "${BUILD_DIR}"

if [[ "${WD}" == "${AUTO_WORKDIR}" ]]; then
    cd /
    rm -rf "${AUTO_WORKDIR}"
fi

info "Done. Clang ${LLVM_VERSION} installed at ${INSTALL_DIR}"
