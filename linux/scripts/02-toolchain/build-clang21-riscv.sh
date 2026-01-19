#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# build-clang21-riscv.sh
# Builds LLVM/Clang 21 natively on riscv64 Ubuntu, installs to the given prefix,
# makes the installed clang the system default, and removes build artifacts to save space.
#
# Usage:
#   ./build-clang21-riscv.sh /opt/llvm-21
#   ./build-clang21-riscv.sh /opt/llvm-21 --no-bootstrap   # skip bootstrap stage
#
# NOTE: This script will remove the source/build directories.
#       Build-time apt packages are always kept (debug-friendly).
#


_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_HELPERS_LOADED=""
# Prefer the shared helpers (common.sh sources parallelism.sh). In the Docker build,
# core scripts are symlinked into the toolchain directory.
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
  ./build-clang21-riscv.sh [PREFIX] [options]

Options:
  --no-bootstrap      Skip bootstrap stage
  --no-strip          Skip stripping installed binaries
  --keep-src          Do not delete the llvm-project source directory
  --keep-build        Do not delete the build directory
  --tag <git-tag>     LLVM git tag to build (default: llvmorg-21.1.0)
  -h, --help          Show this help

Environment:
  LLVM_BUILD_MB_PER_JOB   Memory cap per job for parallel build (default: 2000)
USAGE
}

PREFIX="/usr/local/llvm-21"
BOOTSTRAP="ON"
LLVM_TAG="llvmorg-21.1.8"
DO_STRIP="1"
KEEP_SRC="0"
KEEP_BUILD="0"

# Backwards compatible: first non-flag argument is PREFIX.
if [ "${1:-}" != "" ] && [[ "${1}" != -* ]]; then
  PREFIX="$1"
  shift || true
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-bootstrap) BOOTSTRAP="OFF"; shift ;;
    --no-strip) DO_STRIP="0"; shift ;;
    --keep-src) KEEP_SRC="1"; shift ;;
    --keep-build) KEEP_BUILD="1"; shift ;;
    --tag)
      [ -n "${2:-}" ] || die "--tag requires a value"
      LLVM_TAG="$2"; shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_sudo
detect_system || true

if [ -n "${ARCH:-}" ] && [ "${ARCH}" != "riscv64" ] && [ "${ARCH}" != "riscv" ]; then
  warn "Detected arch=${ARCH}; this script is intended for riscv64. Proceeding anyway."
fi

# Limit parallelism based on CPU quota and available memory (avoid OOM).
# LLVM/Clang builds can be memory-hungry; default to 2000MB/job.
if command -v compute_jobs_with_mem_cap >/dev/null 2>&1; then
  NUM_JOBS="$(compute_jobs_with_mem_cap "" "${LLVM_BUILD_MB_PER_JOB:-2000}")"
else
  NUM_JOBS="$(nproc || echo 1)"
fi

WD="$(pwd)"
SRC_DIR="${WD}/llvm-project"
BUILD_DIR="${WD}/llvm-build"
INSTALL_DIR="${PREFIX}"

info ""
info "=== Build LLVM/Clang 21 for riscv64 ==="
info "Install prefix: ${INSTALL_DIR}"
info "Bootstrap: ${BOOTSTRAP}"
info "Tag: ${LLVM_TAG}"
info "Jobs: ${NUM_JOBS}"
info ""

info "Proceeding (non-interactive)."

info "Installing build prerequisites (apt packages)..."
apt_install \
  build-essential git cmake ninja-build python3 python3-distutils python3-pip \
  libedit-dev libncurses5-dev zlib1g-dev libxml2-dev libssl-dev pkg-config \
  libffi-dev curl ca-certificates lld file binutils ccache

# clone the llvm project (shallow)
if [[ ! -d "${SRC_DIR}" ]]; then
  info "Cloning llvm-project ${LLVM_TAG}..."
  git clone --depth 1 --branch "${LLVM_TAG}" https://github.com/llvm/llvm-project.git "${SRC_DIR}"
else
  info "Source dir exists, checking out ${LLVM_TAG}..."
  pushd "${SRC_DIR}" >/dev/null
  git fetch --tags origin
  git checkout "${LLVM_TAG}"
  popd >/dev/null
fi

# remove any previous build dir
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

CMAKE_FLAGS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}"
  -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld;compiler-rt"
  -DLLVM_TARGETS_TO_BUILD="RISCV"
  -DLLVM_ENABLE_LTO=Thin
  -DLLVM_ENABLE_ASSERTIONS=ON
  -DCLANG_ENABLE_BOOTSTRAP=${BOOTSTRAP}
  -DLLVM_USE_LINKER=lld
  -DLLVM_ENABLE_TERMINFO=OFF
  -DDEFAULT_SYSROOT=""
)

echo "==> Configuring with CMake..."
cmake "${CMAKE_FLAGS[@]}" "${SRC_DIR}/llvm"

echo "==> Building (this will take a long time)..."
if [[ "${BOOTSTRAP}" == "ON" ]]; then
  cmake --build . --target stage2 --parallel "${NUM_JOBS}"
else
  cmake --build . --parallel "${NUM_JOBS}"
fi

echo "==> Installing to ${INSTALL_DIR} ..."
${SUDO} cmake --build . --target install

echo "==> Registering clang as the system default (update-alternatives)..."
# priority 200 to be preferred over older installations; adjust if needed
PRI=200
BIN_DIR="${INSTALL_DIR}/bin"

# Install/update alternatives for clang and related tools.
# Use --slave to update clang++ and clang-format together with clang.
${SUDO} update-alternatives --install /usr/bin/clang clang "${BIN_DIR}/clang" ${PRI} \
  --slave /usr/bin/clang++ clang++ "${BIN_DIR}/clang++" \
  --slave /usr/bin/clang-format clang-format "${BIN_DIR}/clang-format" || true

# Ensure it's selected
${SUDO} update-alternatives --set clang "${BIN_DIR}/clang" || true

# Register a few additional common LLVM tools when present.
for tool in clangd clang-tidy lld ld.lld; do
  if [[ -x "${BIN_DIR}/${tool}" ]]; then
    ${SUDO} update-alternatives --install "/usr/bin/${tool}" "${tool}" "${BIN_DIR}/${tool}" ${PRI} || true
    ${SUDO} update-alternatives --set "${tool}" "${BIN_DIR}/${tool}" || true
  fi
done

# Optionally register lldb/llvm tools too (uncomment if you installed them)
# sudo update-alternatives --install /usr/bin/llvm-ar llvm-ar "${BIN_DIR}/llvm-ar" ${PRI}
# sudo update-alternatives --set llvm-ar "${BIN_DIR}/llvm-ar"

if [[ "${DO_STRIP}" == "1" ]]; then
  echo "==> Stripping installed binaries/libs to free space..."
  # Strip only ELF executables and shared libs inside the INSTALL_DIR.
  # `file` is used to detect ELF objects. If strip fails for a file, we ignore the error.
  if command -v file >/dev/null 2>&1 && command -v strip >/dev/null 2>&1; then
    echo "Finding ELF files under ${INSTALL_DIR} and stripping them..."
    ${SUDO} find "${INSTALL_DIR}" -type f -print0 \
      | while IFS= read -r -d '' f; do
          if file -b "${f}" 2>/dev/null | grep -q 'ELF'; then
            echo "  strip ${f}"
            ${SUDO} strip --strip-all "${f}" || true
          fi
        done
  else
    echo "strip or file not found; skipping binary strip step."
  fi
else
  echo "==> Skipping strip step (--no-strip)."
fi

echo "==> Removing build artifacts (source & build directories)..."
# Remove source and build directories to free space
if [[ "${KEEP_SRC}" != "1" ]]; then
  rm -rf "${SRC_DIR}"
else
  echo "Keeping source directory (--keep-src): ${SRC_DIR}"
fi

if [[ "${KEEP_BUILD}" != "1" ]]; then
  rm -rf "${BUILD_DIR}"
else
  echo "Keeping build directory (--keep-build): ${BUILD_DIR}"
fi

echo "==> Cleaning apt caches..."
${SUDO} apt-get clean
${SUDO} rm -rf /var/lib/apt/lists/*

echo "==> Keeping build packages (never removed by this script)."

echo
echo "==> Done. Installed clang 21 at: ${INSTALL_DIR}"
echo "To verify:"
echo "  clang --version"
echo "  which clang"
echo
echo "If you want to restore a previous clang installation as default, use update-alternatives:"
echo "  sudo update-alternatives --config clang"
echo
