#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# build-clang21-riscv.sh
# Builds LLVM/Clang 21 natively on riscv64 Ubuntu, installs to the given prefix,
# makes the installed clang the system default, and removes build artifacts to save space.
#
# Usage: ./build-clang21-riscv.sh [PREFIX] [options]
# Options:
#   --no-bootstrap      Skip bootstrap stage
#   --no-strip          Skip stripping binaries
#   --keep-src          Keep llvm-project source
#   --keep-build        Keep build directory
#   --tag <git-tag>     Default: llvmorg-21.1.8
#   --jobs <N> / -j <N> Set number of parallel build jobs (overrides auto choice)

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

Options:
  --no-bootstrap      Skip bootstrap stage
  --no-strip          Skip stripping binaries
  --keep-src          Keep llvm-project source
  --keep-build        Keep build directory
  --tag <git-tag>     Default: llvmorg-21.1.8
  --jobs <N> / -j <N> Set number of parallel build jobs (overrides auto choice)
USAGE
}

# --- Default Values ---
PREFIX="/usr/local/llvm-21"
BOOTSTRAP="ON"
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

# --- Initialization (Fixed variable order) ---
WD="$(pwd)"
SRC_DIR="${WD}/llvm-project"
BUILD_DIR="${WD}/llvm-build"
INSTALL_DIR="${PREFIX}"

require_sudo
detect_system || true

# ====== Preflight Checks ======
run_preflight_checks() {
    info "---- preflight: workdir safety ----"
    [ -z "${WD:-}" ] || [ "${WD}" = "/" ] && die "Unsafe WD: ${WD}"

    info "---- preflight: tools ----"
    for t in git cmake ninja python3 /usr/bin/cc ld as file strip; do
        command -v "${t}" >/dev/null 2>&1 || die "Missing tool: ${t}"
    done

    info "---- preflight: disk space ----"
    local avail_mb
    avail_mb=$(df --output=avail -m "${WD}" 2>/dev/null | tail -n1 || echo 0)
    [ "${avail_mb}" -lt 30000 ] && warn "Low disk: ${avail_mb}MB"

    info "---- preflight: compiler test ----"
    mkdir -p "${BUILD_DIR}"
    echo 'int main(){return 0;}' > "${BUILD_DIR}/test.c"
    /usr/bin/cc "${BUILD_DIR}/test.c" -o "${BUILD_DIR}/test" || die "Host compiler broken"
    rm -f "${BUILD_DIR}/test.c" "${BUILD_DIR}/test"
}

run_preflight_checks

# --- Build Logic ---
# Determine number of parallel jobs. Priority:
#  1) CLI --jobs / -j (NUM_JOBS variable set during arg parsing)
#  2) Environment variable CLANG_NUM_JOBS (must be numeric)
#  3) compute_jobs_with_mem_cap (if available)
#  4) nproc
if [ -n "${NUM_JOBS:-}" ] && [[ "${NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    : # NUM_JOBS was set via CLI
elif [ -n "${CLANG_NUM_JOBS:-}" ] && [[ "${CLANG_NUM_JOBS}" =~ ^[0-9]+$ ]]; then
    NUM_JOBS="${CLANG_NUM_JOBS}"
elif command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
    NUM_JOBS="$(compute_jobs_with_mem_cap "" "${LLVM_BUILD_MB_PER_JOB:-2000}")"
else
    NUM_JOBS="$(nproc || echo 1)"
fi

info "Using NUM_JOBS=${NUM_JOBS}"

info "Installing dependencies..."
apt_install build-essential git cmake ninja-build python3 libedit-dev \
    libncurses5-dev zlib1g-dev libxml2-dev libssl-dev pkg-config \
    libffi-dev curl ca-certificates lld file binutils ccache

if [[ ! -d "${SRC_DIR}" ]]; then
  info "Cloning llvm-project ${LLVM_TAG}..."
  git clone --depth 1 --branch "${LLVM_TAG}" https://github.com/llvm/llvm-project.git "${SRC_DIR}"
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Note: LLVM_ENABLE_LTO=OFF used to prevent GCC from failing on ThinLTO flags
CMAKE_FLAGS=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;compiler-rt"
    -DLLVM_TARGETS_TO_BUILD="RISCV"
    -DLLVM_ENABLE_LTO=OFF
    -DLLVM_ENABLE_ASSERTIONS=ON
    -DCLANG_ENABLE_BOOTSTRAP=${BOOTSTRAP}
    -DLLVM_USE_LINKER=lld
    -DLLVM_ENABLE_TERMINFO=OFF
)

echo "==> Configuring..."
cmake "${CMAKE_FLAGS[@]}" "${SRC_DIR}/llvm"

echo "==> Building (this will take a long time)..."
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
    --slave /usr/bin/clang-format clang-format "${BIN_DIR}/clang-format" || true
${SUDO} update-alternatives --set clang "${BIN_DIR}/clang" || true

if [[ "${DO_STRIP}" == "1" ]]; then
    info "Stripping binaries..."
    ${SUDO} find "${INSTALL_DIR}" -type f -exec sh -c 'file "{}" | grep -q ELF && strip --strip-all "{}"' \; || true
fi

[[ "${KEEP_SRC}" != "1" ]] && rm -rf "${SRC_DIR}"
[[ "${KEEP_BUILD}" != "1" ]] && rm -rf "${BUILD_DIR}"

info "Done. Clang 21 installed at ${INSTALL_DIR}"
