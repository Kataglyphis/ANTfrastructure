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

# ====== START: exhaustive preflight tests for riscv clang build ======
# Insert this block after require_sudo and detect_system (i.e. before heavy work).

# Minimum required CMake version (tunable)
MIN_CMAKE_MAJOR=3
MIN_CMAKE_MINOR=20

# Minimum recommended free disk (MB) and RAM (MB)
RECOMMENDED_DISK_MB=30000   # 30 GB free recommended
RECOMMENDED_RAM_MB=16000    # 16 GB recommended (more for bootstrap/LTO)

# Helper: version compare (returns 0 if $1 >= $2)
ver_ge() {
  # usage: ver_ge "3.22.1" "3.20"
  [ "$#" -eq 2 ] || return 2
  printf '%s\n%s\n' "$1" "$2" | awk -F. '{
    for(i=1;i<=3;i++){ a[i]=($i==""?0:$i) }
    split($0,_, "\n")
  }' >/dev/null 2>&1
  # simpler numeric compare:
  dpkg --compare-versions "$1" ge "$2"
}

# Print header helper
_test_header() { info "---- preflight: $* ----"; }

# 1) Safe working directory
preflight_check_workdir() {
  _test_header "workdir safety"
  if [ -z "${WD:-}" ] || [ "${WD}" = "/" ]; then
    die "Refusing to run with unsafe working directory: ${WD:-<empty>}"
  fi
  info "WD OK: ${WD}"
}

# 2) Basic tool presence and minimal versions
preflight_check_tools() {
  _test_header "tools: git cmake ninja python3 cc ld as file strip"
  local missing=()
  for t in git cmake ninja python3 /usr/bin/cc ld as file strip; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      missing+=("${t}")
    fi
  done
  if [ ${#missing[@]} -ne 0 ]; then
    die "Missing required tools: ${missing[*]}. Install them (e.g. apt-get install git cmake ninja-build python3 build-essential binutils file)."
  fi

  # cmake version
  cmake_ver="$(cmake --version | head -n1 | awk '{print $3}')"
  if ! ver_ge "${cmake_ver}" "${MIN_CMAKE_MAJOR}.${MIN_CMAKE_MINOR}"; then
    warn "CMake ${cmake_ver} < recommended ${MIN_CMAKE_MAJOR}.${MIN_CMAKE_MINOR}. Consider installing newer CMake."
  else
    info "CMake OK: ${cmake_ver}"
  fi

  info "git: $(git --version | head -n1)"
  info "ninja: $(ninja --version 2>/dev/null || echo 'ninja: unknown')"
}

# 3) Disk & tmp mount checks
preflight_check_disk_tmp() {
  _test_header "disk & tmp"
  local avail_mb
  avail_mb=$(df --output=avail -m "${WD}" 2>/dev/null | tail -n1 || echo 0)
  if [ "${avail_mb:-0}" -lt "${RECOMMENDED_DISK_MB}" ]; then
    warn "Low free space in ${WD}: ${avail_mb} MB available; ${RECOMMENDED_DISK_MB} MB recommended."
  else
    info "Disk: ${avail_mb} MB available in ${WD}"
  fi

  # check /tmp exec
  tmp_exec_test="/tmp/preflight_exec_test_$$"
  cat > "${tmp_exec_test}.c" <<'C'
int main(void){return 0;}
C
  if ! gcc "${tmp_exec_test}.c" -o "${tmp_exec_test}" >/dev/null 2>&1; then
    warn "Building small executable in current environment failed; /tmp might be noexec or gcc missing for the host arch."
  else
    if ! "${tmp_exec_test}" >/dev/null 2>&1; then
      warn "Executable in /tmp failed to run; /tmp may be mounted nosuid/noexec or QEMU/binfmt not configured for riscv."
    else
      info "/tmp exec test OK"
    fi
  fi
  rm -f "${tmp_exec_test}.c" "${tmp_exec_test}" || true
}

# 4) Memory & swap checks
preflight_check_memory() {
  _test_header "memory & swap"
  local mem_mb swap_mb
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  swap_mb=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  info "RAM: ${mem_mb} MB, SWAP: ${swap_mb} MB"
  if [ "${mem_mb:-0}" -lt "${RECOMMENDED_RAM_MB}" ]; then
    warn "System RAM < ${RECOMMENDED_RAM_MB}MB; full bootstrap or LTO builds may OOM. Consider --no-bootstrap, adding swap, or building on beefier hardware."
  fi
}

# 5) Arch and runtime executable test (critical)
preflight_check_arch_and_run() {
  _test_header "architecture & runability of riscv binaries"
  local host_arch dpkg_arch uname_m
  dpkg_arch="$(dpkg --print-architecture 2>/dev/null || true)"
  uname_m="$(uname -m 2>/dev/null || true)"
  info "dpkg arch=${dpkg_arch}, uname -m=${uname_m}, expected riscv64"

  if [ "${dpkg_arch}" != "riscv64" ] && [ "${uname_m}" != "riscv64" ]; then
    warn "Host reports non-riscv arch. You may be cross-building in a non-riscv environment. CMake will compile-and-run tests which require qemu/binfmt for emulation."
  fi

  # try compile small riscv test using /usr/bin/cc (may be a riscv cross compiler or native)
  cat > "${BUILD_DIR}/cctest.c" <<'C'
#include <stdio.h>
int main(void){ puts("hello"); return 0; }
C
  set +e
  /usr/bin/cc "${BUILD_DIR}/cctest.c" -o "${BUILD_DIR}/cctest" &> "${BUILD_DIR}/cctest.log"
  cc_ret=$?
  set -e
  if [ "${cc_ret}" -ne 0 ]; then
    echo "[ERROR] /usr/bin/cc failed to produce a test binary. See ${BUILD_DIR}/cctest.log:"
    sed -n '1,200p' "${BUILD_DIR}/cctest.log" || true
    die "C compiler is not able to compile a simple test program. Likely missing libc dev files (libc6-dev:riscv64) or cross-compiler mismatch."
  fi

  # If binary exists, check file/exec
  if [ -f "${BUILD_DIR}/cctest" ]; then
    file_out="$(file -b "${BUILD_DIR}/cctest" 2>/dev/null || true)"
    info "Test binary type: ${file_out}"
    # Try run; if Exec format error, qemu/binfmt missing
    set +e
    "${BUILD_DIR}/cctest" >/dev/null 2>&1
    run_ret=$?
    set -e
    if [ "${run_ret}" -eq 126 ] || [ "${run_ret}" -eq 127 ]; then
      warn "Test binary produced but failed to run (exit ${run_ret}). Might be 'Exec format error' — QEMU/binfmt missing."
      if command -v qemu-riscv64 >/dev/null 2>&1 || command -v qemu-riscv64-static >/dev/null 2>&1; then
        info "qemu-user is present on the system."
      else
        warn "qemu-user-static not found. To run riscv binaries on a non-riscv host, install qemu-user-static and register binfmt (binfmt-support). Example: apt-get install -y qemu-user-static binfmt-support"
      fi
      # Dump binfmt status
      if [ -d /proc/sys/fs/binfmt_misc ]; then
        info "binfmt_misc entries:"
        ls /proc/sys/fs/binfmt_misc || true
        grep -i riscv /proc/sys/fs/binfmt_misc/* 2>/dev/null || true
      fi
      die "Cannot run produced riscv test binary in this environment; enable QEMU/binfmt or build on native riscv."
    else
      info "Test program compiled and ran successfully."
    fi
  else
    die "Test binary not found after compilation; aborting."
  fi
  rm -f "${BUILD_DIR}/cctest.c" "${BUILD_DIR}/cctest" "${BUILD_DIR}/cctest.log" || true
}

# 6) Check for libc dev files and crt objects
preflight_check_libc_crt() {
  _test_header "libc dev / crt objects"
  local found=0
  for p in /usr/lib/*/crt1.o /usr/lib/*/crti.o /usr/lib/*/crtn.o /usr/lib/crt1.o; do
    if [ -f "${p}" ]; then found=1; break; fi
  done
  if [ "${found}" -eq 0 ]; then
    warn "crt1.o/crti.o/crtn.o not found in /usr/lib; install libc6-dev or libc6-dev:riscv64."
  else
    info "CRT files present."
  fi
}

# 7) binutils / linker / assembler presence & sanity
preflight_check_binutils() {
  _test_header "binutils/linker/assembler"
  for t in ld as objdump; do
    if ! command -v "${t}" >/dev/null 2>&1; then
      die "Required binutils tool not found: ${t}. Install binutils."
    fi
  done
  info "ld: $(ld --version | head -n1 2>/dev/null || echo 'unknown')"
  info "as: $(as --version | head -n1 2>/dev/null || echo 'unknown')"
}

# 8) LLD presence if we plan to use it
preflight_check_lld() {
  _test_header "lld presence (requested linker)"
  if [[ " ${CMAKE_FLAGS[*]} " == *"LLVM_USE_LINKER=lld"* ]]; then
    if ! command -v ld.lld >/dev/null 2>&1 && ! command -v lld >/dev/null 2>&1; then
      warn "lld requested (CMAKE_FLAGS contains LLVM_USE_LINKER=lld) but lld not found in PATH. CMake may still build without forcing lld but performance/compatibility may differ."
    else
      info "lld found: $(ld.lld --version 2>/dev/null | head -n1 || lld --version 2>/dev/null | head -n1 || echo 'unknown')"
    fi
  fi
}

# 9) Git tag existence (avoids shallow clone surprises)
preflight_check_git_tag() {
  _test_header "git tag availability: ${LLVM_TAG}"
  if git ls-remote --tags https://github.com/llvm/llvm-project.git "${LLVM_TAG}" | grep -q "${LLVM_TAG}"; then
    info "Tag ${LLVM_TAG} exists on remote."
  else
    warn "Tag ${LLVM_TAG} not found on remote; clone may fail or fallback to default branch."
  fi
}

# 10) Environment considerations (CC/CXX/LD flags, sandbox)
preflight_check_env() {
  _test_header "environment variables"
  for v in CC CXX AR RANLIB LD LDFLAGS CFLAGS CXXFLAGS; do
    if [ -n "${!v:-}" ]; then
      warn "Environment variable ${v} is set (value='${!v}'). This may influence the build."
    fi
  done
}

# 11) Strip / file required if DO_STRIP
preflight_check_strip_tools() {
  _test_header "strip/file availability (for DO_STRIP)"
  if [[ "${DO_STRIP}" == "1" ]]; then
    for t in file strip readelf; do
      if ! command -v "${t}" >/dev/null 2>&1; then
        warn "Tool '${t}' not found but DO_STRIP=1. Stripping will be skipped or may be unsafe."
      fi
    done
  fi
}

# 12) ulimit check
preflight_check_ulimit() {
  _test_header "ulimit"
  local nproc_ulimit open_ulimit stack_kb
  open_ulimit="$(ulimit -n || echo unknown)"
  stack_kb="$(ulimit -s || echo unknown)"
  info "ulimit -n (open files): ${open_ulimit}; ulimit -s (stack KB): ${stack_kb}"
  if [ "${open_ulimit}" != "unknown" ] && [ "${open_ulimit}" -lt 1024 ]; then
    warn "ulimit -n is low (<1024); builds may open many files."
  fi
}

# Run all preflight checks
run_preflight_checks() {
  preflight_check_workdir
  preflight_check_tools
  preflight_check_disk_tmp
  preflight_check_memory
  # ensure BUILD_DIR exists so cctest has somewhere to write
  mkdir -p "${BUILD_DIR}"
  preflight_check_arch_and_run
  preflight_check_libc_crt
  preflight_check_binutils
  preflight_check_lld
  preflight_check_git_tag
  preflight_check_env
  preflight_check_strip_tools
  preflight_check_ulimit
  info "Preflight checks completed."
}

# Call the checks now
run_preflight_checks

# ====== END: exhaustive preflight tests ======


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
  build-essential git cmake ninja-build python3 python3-pip \
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
