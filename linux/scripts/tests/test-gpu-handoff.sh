#!/usr/bin/env bash
# Synthetic OCI bytes and command doubles test binding and refusals, not provenance authentication, real builds or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/gpu_handoff_tests.py" "$@"
