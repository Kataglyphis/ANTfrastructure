#!/usr/bin/env bash
# Native extraction proves selected binary bytes, not provenance, executable mode or loader behavior.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/../01-core/platform.sh"
source "${script_dir}/appimage-verification.sh"
appimage_verify_file "${script_dir}/../verify_package_binary.py" "$@"
