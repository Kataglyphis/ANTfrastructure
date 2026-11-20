#!/usr/bin/env bash
# Synthetic caches and a unit double do not prove actual cache hits or image acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/buildcache_transfer_tests.py" "$@"
