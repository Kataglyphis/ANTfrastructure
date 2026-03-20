#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

init_defaults
detect_jobs

LITERT_REPO="${LITERT_REPO:-https://github.com/google/litert.git}"
LITERT_VERSION="${LITERT_VERSION:-main}"
LITERT_SRC_DIR="${LITERT_SRC_DIR:-/opt/litert}"
LITERT_BUILD_DIR="${LITERT_BUILD_DIR:-${LITERT_SRC_DIR}/build}"
LITERT_OUTPUT_DIR="${LITERT_OUTPUT_DIR:-/usr/local/lib/litert}"
LITERT_CONFIG="${LITERT_CONFIG:-Release}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --litert-version <tag>   LiteRT git tag/branch to checkout (default: ${LITERT_VERSION})
  --litert-repo <url>      LiteRT git repository (default: ${LITERT_REPO})
  --litert-src <dir>       LiteRT source directory (default: ${LITERT_SRC_DIR})
  --litert-build <dir>     LiteRT build directory (default: ${LITERT_BUILD_DIR})
  --litert-out <dir>       LiteRT install/output dir (default: ${LITERT_OUTPUT_DIR})
  --litert-config <cfg>    CMake build type (Release|RelWithDebInfo|Debug|MinSizeRel) (default: ${LITERT_CONFIG})
  -h, --help               Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --litert-version)
      [ $# -ge 2 ] || err "--litert-version requires a value"
      LITERT_VERSION="$2"
      shift 2
      ;;
    --litert-repo)
      [ $# -ge 2 ] || err "--litert-repo requires a value"
      LITERT_REPO="$2"
      shift 2
      ;;
    --litert-src)
      [ $# -ge 2 ] || err "--litert-src requires a value"
      LITERT_SRC_DIR="$2"
      shift 2
      ;;
    --litert-build)
      [ $# -ge 2 ] || err "--litert-build requires a value"
      LITERT_BUILD_DIR="$2"
      shift 2
      ;;
    --litert-out)
      [ $# -ge 2 ] || err "--litert-out requires a value"
      LITERT_OUTPUT_DIR="$2"
      shift 2
      ;;
    --litert-config)
      [ $# -ge 2 ] || err "--litert-config requires a value"
      LITERT_CONFIG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1 (use --help)"
      ;;
  esac
done

validate_build_type "${LITERT_CONFIG}" "--litert-config"

export LITERT_REPO LITERT_VERSION LITERT_SRC_DIR LITERT_BUILD_DIR LITERT_OUTPUT_DIR LITERT_CONFIG

info "Running LiteRT build/setup (repo=${LITERT_REPO} ref=${LITERT_VERSION})"

require_cmd git
require_cmd cmake
require_cmd ninja || true

mkdir -p "${LITERT_SRC_DIR}"

if [ ! -d "${LITERT_SRC_DIR}/.git" ]; then
  info "Cloning LiteRT into ${LITERT_SRC_DIR}"
  git clone "${LITERT_REPO}" "${LITERT_SRC_DIR}"
fi

pushd "${LITERT_SRC_DIR}" >/dev/null
info "Checking out ${LITERT_VERSION}"
git fetch --all --tags --prune || true
git checkout "${LITERT_VERSION}" || git checkout -b "build-${LITERT_VERSION}" "origin/${LITERT_VERSION}" || true

info "Configuring build in ${LITERT_BUILD_DIR} (config=${LITERT_CONFIG})"
mkdir -p "${LITERT_BUILD_DIR}"
cmake -S . -B "${LITERT_BUILD_DIR}" -G Ninja -DCMAKE_BUILD_TYPE="${LITERT_CONFIG}" -DCMAKE_INSTALL_PREFIX="${LITERT_OUTPUT_DIR}"

info "Building LiteRT (jobs=${JOBS})"
cmake --build "${LITERT_BUILD_DIR}" --parallel "${JOBS}"

info "Installing LiteRT into ${LITERT_OUTPUT_DIR}"
cmake --install "${LITERT_BUILD_DIR}" --parallel "${JOBS}"

popd >/dev/null

# Copy artifacts (libraries and headers) to a predictable location if install did not place them
if [ -d "${LITERT_OUTPUT_DIR}" ]; then
  info "LiteRT successfully installed to ${LITERT_OUTPUT_DIR}"
else
  warn "Expected install directory ${LITERT_OUTPUT_DIR} not found; attempting to collect artifacts manually"
  mkdir -p "${LITERT_OUTPUT_DIR}/lib" "${LITERT_OUTPUT_DIR}/include"
  find "${LITERT_BUILD_DIR}" -type f -name "lib*litert*.so*" -exec cp -v {} "${LITERT_OUTPUT_DIR}/lib/" \; || true
  find "${LITERT_BUILD_DIR}" -type f -name "lib*litert*.a" -exec cp -v {} "${LITERT_OUTPUT_DIR}/lib/" \; || true
  find "${LITERT_SRC_DIR}" -type f -name "*.h" -path "*/include/*" -exec cp -v --parents {} "${LITERT_OUTPUT_DIR}/include/" \; || true
fi

info "LiteRT build/setup complete. Artifacts available at: ${LITERT_OUTPUT_DIR}"
