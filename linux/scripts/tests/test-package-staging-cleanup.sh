#!/usr/bin/env bash
# Temporary fixtures do not prove host quiescence, authenticate observations or validate archive contents.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/package_staging_cleanup_tests.py" "$@"
