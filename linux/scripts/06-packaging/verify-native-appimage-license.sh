#!/usr/bin/env bash
# Checks an AppImage payload on its native architecture, not third-party compliance.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
source "${script_dir}/appimage-verification.sh"
appimage_verify_file "${script_dir}/../verify_package_license.py" "$@"
