#!/usr/bin/env bash
set -euo pipefail

# setup-flutter.sh — unified Flutter SDK installer for amd64 and arm64.
# Downloads the Flutter SDK from Google's CDN and extracts it to the target
# directory.  Replaces the old per-arch setup-flutter-{x86-64,arm64}.sh wrappers.
#
# Usage:
#   setup-flutter.sh --arch x64|arm64 --version 3.44.4 [--dir /opt/flutter]
#
# The --arch flag selects the correct download archive (x86-64 vs arm64).
# riscv64 is rejected — Flutter does not support it.

usage() {
  cat <<EOF
Usage: $0 --arch <x64|arm64> --version <ver> [--dir <path>]

  --arch, -a     Target architecture: x64 or arm64 (riscv64 unsupported)
  --version, -v  Flutter SDK version (e.g. 3.44.4)
  --dir, -d      Installation directory (default: /opt)
  -h, --help     Show this help
EOF
}

ARCH=""
FLUTTER_VERSION=""
INSTALL_DIR="/opt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch|-a)       ARCH="$2"; shift 2 ;;
    --version|-v)    FLUTTER_VERSION="$2"; shift 2 ;;
    --dir|-d)        INSTALL_DIR="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ -z "${ARCH}" ] || [ -z "${FLUTTER_VERSION}" ]; then
  echo "Error: --arch and --version are required" >&2
  usage >&2
  exit 1
fi

case "${ARCH}" in
  x64|x86-64|amd64)
    ARCH_SUFFIX=""
    ARCH_LABEL="x86-64"
    ;;
  arm64|aarch64)
    ARCH_SUFFIX="_arm64"
    ARCH_LABEL="ARM64"
    ;;
  riscv64)
    echo "Error: Flutter does not support riscv64. Skipping." >&2
    exit 0
    ;;
  *)
    echo "Error: unsupported architecture: ${ARCH} (use x64|arm64)" >&2
    exit 1
    ;;
esac

FLUTTER_PATH="${INSTALL_DIR}/flutter"
ARCHIVE="flutter_linux${ARCH_SUFFIX}_${FLUTTER_VERSION}-stable.tar.xz"
URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${ARCHIVE}"

echo "Installing Flutter ${FLUTTER_VERSION} for ${ARCH_LABEL}..."
echo "  Archive: ${ARCHIVE}"
echo "  Target:  ${FLUTTER_PATH}"

wget -q "${URL}"
mkdir -p "${INSTALL_DIR}"
tar xf "${ARCHIVE}" -C "${INSTALL_DIR}"
rm -f "${ARCHIVE}"

# Clean up unnecessary cache artifacts
rm -rf "${FLUTTER_PATH}/bin/cache"

# Verify
export PATH="${FLUTTER_PATH}/bin:${PATH}"
flutter --version 2>&1 | head -1
echo "Flutter installed at ${FLUTTER_PATH}"
