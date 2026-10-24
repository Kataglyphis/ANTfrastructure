#!/usr/bin/env bash
# Full source-order receipts cover selection and readonly outputs, not real privilege escalation; only Bash source locations are normalized.
set -eu
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${tests_dir}/sudo-policy-tests.py" "${1:-${tests_dir}/..}"
