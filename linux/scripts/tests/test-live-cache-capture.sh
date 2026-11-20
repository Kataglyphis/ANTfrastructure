#!/usr/bin/env bash
# Synthetic process files and command doubles prove reader boundaries, never cache-error attribution or an actual build.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/live_cache_capture_tests.py" "$@"
