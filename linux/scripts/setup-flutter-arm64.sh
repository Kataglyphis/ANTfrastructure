#!/usr/bin/env bash
set -euo pipefail
# Forwarding wrapper — legacy path expected by ExternalLib consumers.
# Calls the canonical script at 05-frameworks/flutter/setup-flutter.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load canonical versions.env if FLUTTER_VERSION is unset so the fallback
# never drifts from linux/scripts/01-core/versions.env.
if [ -z "${FLUTTER_VERSION:-}" ] && [ -f "${SCRIPT_DIR}/01-core/versions.env" ]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/01-core/load-versions-env.sh"
  load_versions_env "${SCRIPT_DIR}/01-core/versions.env"
fi

FLUTTER_VERSION="${1:-${FLUTTER_VERSION:-3.44.4}}"
INSTALL_DIR="${2:-/opt}"
exec "${SCRIPT_DIR}/05-frameworks/flutter/setup-flutter.sh" \
  --arch arm64 --version "${FLUTTER_VERSION}" --dir "${INSTALL_DIR}"
