#!/usr/bin/env bash
# Tests archive content and failure preservation, not Cython or compiler selection.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/test-wheel-rewrite.py"
