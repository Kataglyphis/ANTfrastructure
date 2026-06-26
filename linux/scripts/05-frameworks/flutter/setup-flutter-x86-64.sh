#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------
# Setup Flutter SDK on x86-64 (Linux)
# ------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./setup-flutter-common.sh
source "${SCRIPT_DIR}/setup-flutter-common.sh"

FLUTTER_VERSION="${1:-${FLUTTER_VERSION:-3.41.4}}"
FLUTTER_DIR="${2:-/opt}"

setup_flutter "x86-64" "${FLUTTER_VERSION}" "${FLUTTER_DIR}"
