#!/usr/bin/env bash
# Synthetic OCI layouts exercise target-bound wiring, not built Media products or hardware.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/default_handoff_tests.py" "$@"
