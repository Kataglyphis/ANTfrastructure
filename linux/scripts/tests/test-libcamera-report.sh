#!/usr/bin/env bash
# Stubbed report receipts cover command bindings and verdicts, not real camera plugins or interactive shell startup.
set -eu
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${tests_dir}/libcamera-report-tests.py" "${1:-${tests_dir}/../04-runtime/libcamera-env.sh}"
