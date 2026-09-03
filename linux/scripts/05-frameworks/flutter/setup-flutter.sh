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

# download_and_extract (retry-capable, temp-file hygiene) lives in
# 01-core/downloads.sh; load it directly since this installer runs standalone.
if ! command -v download_and_extract >/dev/null 2>&1; then
  for _flutter_dl in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/downloads.sh" \
    "/opt/scripts/core/downloads.sh"; do
    if [ -f "${_flutter_dl}" ]; then
      # shellcheck disable=SC1090
      source "${_flutter_dl}"
      break
    fi
  done
  unset _flutter_dl
fi

# VERIFIED fetch (supply-chain audit #9): this is the Dart/Flutter COMPILER
# toolchain, executed at build time — Google publishes the official sha256 in
# releases_linux.json; FLUTTER_SDK_SHA256 mirrors it (bump with FLUTTER_VERSION).
# noforward pin: read it from the mounted versions.env when the env lacks it.
if [ -z "${FLUTTER_SDK_SHA256:-}" ]; then
  _flutter_pinned_version=""
  for _flutter_ve in /opt/scripts/core/versions.env \
      "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../01-core/versions.env"; do
    if [ -f "${_flutter_ve}" ]; then
      FLUTTER_SDK_SHA256="$(sed -n 's/^FLUTTER_SDK_SHA256=//p' "${_flutter_ve}")"
      _flutter_pinned_version="$(sed -n 's/^FLUTTER_VERSION=//p' "${_flutter_ve}")"
      break
    fi
  done

  # The SHA and the version in versions.env are ONE pin, but --version is a
  # caller-supplied parameter - so a consumer can ask for a version the pinned
  # SHA cannot possibly match. That failed as
  #   Checksum verification FAILED for /tmp/flutter-sdk-XXXX.tar.xz
  # which reads like a corrupted download and sent the search in the wrong
  # direction entirely. Measured 2026-08-12: Kataglyphis-Inference-Engine asked
  # for 3.41.6 while versions.env pinned 3.44.9, and all three of its Flutter
  # lanes died here.
  #
  # Say what actually happened instead, and name both ways out.
  if [ -n "${FLUTTER_SDK_SHA256:-}" ] && [ -n "${_flutter_pinned_version}" ] \
     && [ "${_flutter_pinned_version}" != "${FLUTTER_VERSION}" ]; then
    echo "ERROR: asked to install Flutter ${FLUTTER_VERSION}, but the pinned checksum in" >&2
    echo "       ${_flutter_ve} belongs to ${_flutter_pinned_version}." >&2
    echo "       The version and its sha256 are one pin; overriding only the version can never verify." >&2
    echo "       Either request ${_flutter_pinned_version}, or pass FLUTTER_SDK_SHA256 for ${FLUTTER_VERSION}" >&2
    echo "       (Google publishes it in releases_linux.json)." >&2
    exit 1
  fi
  unset _flutter_ve _flutter_pinned_version
fi
if [ -n "${FLUTTER_SDK_SHA256:-}" ]; then
  _flutter_tmp="$(mktemp "${TMPDIR:-/tmp}/flutter-sdk-XXXXXX.tar.xz")"
  download_verified_file "${URL}" "${FLUTTER_SDK_SHA256}" "${_flutter_tmp}"
  mkdir -p "${INSTALL_DIR}"
  tar -xJf "${_flutter_tmp}" -C "${INSTALL_DIR}"
  rm -f "${_flutter_tmp}"
else
  echo "WARNING: FLUTTER_SDK_SHA256 unset — fetching the Flutter toolchain UNVERIFIED (official sha lives in releases_linux.json; pin it in versions.env)" >&2
  download_and_extract "${URL}" "${INSTALL_DIR}"
fi

# Ship the checkout BARE: this stage runs on the amd64 host for every arch, so
# anything `flutter` cached here would be the host's Dart SDK, stamped as
# current and never replaced on arm64. The package stage bootstraps per arch.
# docs/artifact-copy-completeness.md#bootstrapping-flutter-in-the-package-stage
rm -rf "${FLUTTER_PATH}/bin/cache"
echo "Flutter ${FLUTTER_VERSION} installed bare at ${FLUTTER_PATH} (Dart SDK bootstraps in the package stage)"
