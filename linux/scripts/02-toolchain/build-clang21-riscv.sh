#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# build-clang21-riscv.sh
# MODIFIED: Disabled Tests/Examples + Dynamic RAM config + Root-Fix

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HELPERS_LOADED=""
if [ -f "${_SCRIPT_DIR}/common.sh" ]; then
    source "${_SCRIPT_DIR}/common.sh"
    _HELPERS_LOADED=1
elif [ -f "${_SCRIPT_DIR}/../01-core/common.sh" ]; then
    source "${_SCRIPT_DIR}/../01-core/common.sh"
    _HELPERS_LOADED=1
fi

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
Usage: ./build-clang21-riscv.sh [PREFIX] [options]
USAGE
}

# --- Default Values ---
PREFIX="/usr/local/llvm-21"
ARCH="$(uname -m)"

# Default settings
if [ "$ARCH" = "riscv64" ]; then
    BOOTSTRAP="OFF"
    info "RISC-V detected: Defaulting to NO-BOOTSTRAP to save time."
else
    BOOTSTRAP="ON"
fi

LLVM_TAG="llvmorg-21.1.8"
DO_STRIP="1"
KEEP_SRC="0"
KEEP_BUILD="0"

if [ "${1:-}" != "" ] && [[ "${1}" != -* ]]; then
    PREFIX="$1"
    shift || true
fi

# Parse options
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-bootstrap) BOOTSTRAP="OFF"; shift ;; 
        --bootstrap)    BOOTSTRAP="ON"; shift ;;
        --no-strip) DO_STRIP="0"; shift ;; 
        --keep-src) KEEP_SRC="1"; shift ;; 
        --keep-build) KEEP_BUILD="1"; shift ;; 
        --tag) LLVM_TAG="$2"; shift 2 ;; 
        --jobs|-j)
            if [ -n "${2:-}" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
                NUM_JOBS="$2"
                shift 2
            else
                die "--jobs requires a numeric argument"
            fi
            ;;
        -h|--help) usage; exit 0 ;; 
        *) die "Unknown option: $1" ;; 
    esac
done

# --- Initialization & WORKDIR FIX ---
WD="$(pwd)"

# FIX: Check if we are in Root (/) and move to a safe place if so
if [ "${WD}" = "/" ]; then
    warn "Detected execution from Root (/). Creating safe workspace in /tmp/llvm-work..."
    mkdir -p /tmp/llvm-work
    cd /tmp/llvm-work
    WD="/tmp/llvm-work"
fi

SRC_DIR="${WD}/llvm-project"
BUILD_DIR="${WD}/llvm-build"
INSTALL_DIR="${PREFIX}"

require_sudo
detect_system || true

# ====== Preflight Checks ======
run_preflight_checks() {
    info "---- preflight: workdir safety ----"
    [ -z "${WD:-}" ] || [ "${WD}" = "/" ] && die "Unsafe WD: ${WD} (Should have been fixed)"

    info "---- preflight: tools ----"
    for t in git cmake ninja python3 file strip; do
        command -v "${t}" >/dev/null 2>&1 || die "Missing tool: ${t}"
    done

    info "---- preflight: disk space ----"
    local avail_mb
    avail_mb=$(df --output=avail -m "${WD}" 2>/dev/null | tail -n1 || echo 0)
    # FIX: Use if-statement to avoid crash if space is SUFFICIENT
    if [ "${avail_mb}" -lt 15000 ]; then
        warn "Low disk: ${avail_mb}MB"
    fi
}

# --- DYNAMIC JOB CALCULATION ---
if [ -n "${NUM_JOBS:-}" ] && [[ "${NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    : # Explicitly set by user, respect it.
elif [ -n "${CLANG_NUM_JOBS:-}" ] && [[ "${CLANG_NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    NUM_JOBS="${CLANG_NUM_JOBS}"
else
    # Auto-Calculate based on RAM
    if [ -f /proc/meminfo ]; then
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    else
        TOTAL_MEM_MB=8000
    fi

    AVAIL_CORES=$(nproc || echo 1)
    
    # Logic: 2000MB per Job
    MEM_LIMIT_JOBS=$((TOTAL_MEM_MB / 2000))
    if [ "$MEM_LIMIT_JOBS" -lt 1 ]; then MEM_LIMIT_JOBS=1; fi

    if [ "$ARCH" = "riscv64" ]; then
        if [ "$AVAIL_CORES" -le "$MEM_LIMIT_JOBS" ]; then
            NUM_JOBS="$AVAIL_CORES"
            info "RISC-V Job Config: RAM is sufficient ($TOTAL_MEM_MB MB). Using all $NUM_JOBS cores."
        else
            NUM_JOBS="$MEM_LIMIT_JOBS"
            warn "RISC-V Job Config: Limiting to $NUM_JOBS jobs to prevent OOM ($TOTAL_MEM_MB MB RAM detected). Available Cores: $AVAIL_CORES."
        fi
    else
        NUM_JOBS="$AVAIL_CORES"
    fi
fi
info "Using NUM_JOBS=${NUM_JOBS}"

info "Installing dependencies..."
apt_install build-essential git cmake ninja-build python3 libedit-dev \
    libncurses5-dev zlib1g-dev libxml2-dev libssl-dev pkg-config \
    libffi-dev curl ca-certificates file binutils ccache

# Try to install LLD gently
if ${SUDO} apt-get install -y lld >/dev/null 2>&1; then
    info "LLD installed successfully."
    HAS_LLD=1
else
    warn "LLD package not found or failed to install. Will fallback to Gold/BFD."
    HAS_LLD=0
fi

run_preflight_checks

if [[ ! -d "${SRC_DIR}" ]]; then
  info "Cloning llvm-project ${LLVM_TAG}..."
  git clone --depth 1 --branch "${LLVM_TAG}" https://github.com/llvm/llvm-project.git "${SRC_DIR}"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Check architecture: Force default linker (BFD) on RISC-V to fix GCC 15 compat
if [ "$(uname -m)" = "riscv64" ]; then
    LINKER_FLAG=""
else
    # Standard logic for other architectures
    if [ "$HAS_LLD" = "1" ]; then
        LINKER_FLAG="-DLLVM_USE_LINKER=lld"
    elif command -v ld.gold >/dev/null 2>&1; then
        LINKER_FLAG="-DLLVM_USE_LINKER=gold"
    else
        LINKER_FLAG=""
    fi
fi

# FIX: Try to find GCC/G++ specifically if CC not set
if [ -z "${CC:-}" ]; then
    if command -v gcc >/dev/null 2>&1; then export CC=gcc; fi
    if command -v g++ >/dev/null 2>&1; then export CXX=g++; fi
fi

# NEW: Explicitly disable Tests, Examples and Benchmarks
CMAKE_FLAGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;compiler-rt"
    -DLLVM_TARGETS_TO_BUILD="RISCV"
    -DLLVM_ENABLE_LTO=OFF
    -DLLVM_ENABLE_ASSERTIONS=ON
    -DCLANG_ENABLE_BOOTSTRAP=${BOOTSTRAP}
    ${LINKER_FLAG}
    -DLLVM_ENABLE_TERMINFO=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_EXAMPLES=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DCLANG_INCLUDE_TESTS=OFF
)

echo "==> Configuring with: ${LINKER_FLAG} and Bootstrap=${BOOTSTRAP}"
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
${SUDO} update-alternatives --install /usr/bin/clang clang "${BIN_DIR}/clang" 200 \
    --slave /usr/bin/clang++ clang++ "${BIN_DIR}/clang++" \
    --slave /usr/bin/clang-format clang-format "${BIN_DIR}/clang-format" \
    --slave /usr/bin/clang-tidy clang-tidy "${BIN_DIR}/clang-tidy" \
    --slave /usr/bin/clangd clangd "${BIN_DIR}/clangd" \
    --slave /usr/bin/ld.lld ld.lld "${BIN_DIR}/ld.lld" || true

${SUDO} update-alternatives --set clang "${BIN_DIR}/clang" || true

if [[ "${DO_STRIP}" == "1" ]]; then
    info "Stripping binaries..."
    ${SUDO} find "${INSTALL_DIR}" -type f -exec sh -c 'file "{}" | grep -q ELF && strip --strip-all "{}"' \; || true
fi

[[ "${KEEP_SRC}" != "1" ]] && rm -rf "${SRC_DIR}"
[[ "${KEEP_BUILD}" != "1" ]] && rm -rf "${BUILD_DIR}"

if [[ "${WD}" == "/tmp/llvm-work" ]]; then
    cd /
    rm -rf "/tmp/llvm-work"
fi

info "Done. Clang 21 installed at ${INSTALL_DIR}"
