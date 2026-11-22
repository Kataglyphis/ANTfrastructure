#!/usr/bin/env bash
# Synthetic OCI layouts exercise the NVIDIA source wiring without building either architecture.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/nvidia_handoff_tests.py" "$@"
