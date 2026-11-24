#!/usr/bin/env bash
# Synthetic receipt and command fixtures cannot prove service execution or image acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/complete_preflight_receipt_tests.py" "$@"
