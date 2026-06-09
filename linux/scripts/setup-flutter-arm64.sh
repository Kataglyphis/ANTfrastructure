#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------
# Setup Flutter SDK on ARM64 (Linux)
# ------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./setup-flutter-common.sh
source "${SCRIPT_DIR}/setup-flutter-common.sh"

FLUTTER_VERSION="${1:-3.41.4}"
FLUTTER_DIR="${2:-/opt}"

setup_flutter "ARM64" "${FLUTTER_VERSION}" "${FLUTTER_DIR}"
