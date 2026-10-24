#!/usr/bin/env bash
# Gst uses its production zero-argument resolver contract; receipts cover alias argv and copied owners, not builds or external resolver arguments.
set -eu
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${tests_dir}/python-provider-context-tests.py" "${1:-${tests_dir}/..}"
