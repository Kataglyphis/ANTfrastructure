#!/usr/bin/env bash
# Synthetic lifecycle controls cannot prove real cleanup timing, capacity or image acceptance.
set -euo pipefail
python3 -B "$(dirname "$0")/runtime_storage_guard_tests.py"
