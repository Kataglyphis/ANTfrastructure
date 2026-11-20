#!/usr/bin/env bash
# Synthetic OCI and command doubles cover admission; they do not build a backend, authenticate receipts or prove GPU inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/normal_stage_tests.py" "$@"
