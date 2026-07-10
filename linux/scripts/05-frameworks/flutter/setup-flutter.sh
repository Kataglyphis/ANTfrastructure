#!/usr/bin/env bash
set -euo pipefail

# setup-flutter.sh — unified Flutter SDK installer for amd64 and arm64.
# Downloads the Flutter SDK from Google's CDN and extracts it to the target
# directory.  Replaces the old per-arch setup-flutter-{x86-64,arm64}.sh wrappers.
#
# Usage:
#   setup-flutter.sh --arch x64|arm64 --version 3.44.4 [--dir /opt/flutter]
#
# NOTE on --arch: Google publishes NO linux-arm64 Flutter SDK archive, so
# arm64 DELIBERATELY receives the same x86-64 archive as x64 (see commit
# ac13fc3); the flag only validates the target. riscv64 is skipped (exit 0)
# — Flutter does not support it.

usage() {
  cat <<EOF
Usage: $0 --arch <x64|arm64> --version <ver> [--dir <path>]

  --arch, -a     Target architecture: x64 or arm64 (riscv64 unsupported).
                 arm64 receives the x86-64 archive — Google ships no
                 linux-arm64 Flutter SDK.
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
    # Deliberate: no linux-arm64 SDK exists upstream — arm64 gets the x86-64
    # archive (same ARCHIVE name below). Do not "fix" this to a per-arch URL.
    ARCH_SUFFIX=""
    ARCH_LABEL="arm64 (using the x86-64 archive — Google ships no linux-arm64 SDK)"
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

# Verify (best-effort, but never silent: on arm64 the x86-64 tooling may not
# execute natively — warn instead of masking the failure entirely)
export PATH="${FLUTTER_PATH}/bin:${PATH}"
if _flutter_ver="$(flutter --version 2>&1)"; then
  printf '%s\n' "${_flutter_ver}" | head -1
else
  echo "WARNING: 'flutter --version' failed after install (expected on arm64, where the x86-64 archive cannot run natively): $(printf '%s' "${_flutter_ver}" | head -1)" >&2
fi
echo "Flutter installed at ${FLUTTER_PATH}"
