#!/usr/bin/env bash
# Synthetic closed receipts and real local Git prove refusals, never a live full preflight or image acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/direct_preflight_receipt_tests.py" "$@"
