#!/usr/bin/env bash
# Synthetic native byte and command fixtures cover refusals, not a real Media/Android build, authenticated receipts or hardware.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/media_handoff_tests.py" "$@"
