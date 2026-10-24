#!/usr/bin/env bash
# Offline receipts cover caller bindings and optional pin failures, not actual system library repair.
set -eu
exec python3 "$(dirname "${BASH_SOURCE[0]}")/media-pin-advisory-tests.py" "$@"
