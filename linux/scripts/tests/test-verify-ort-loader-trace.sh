#!/usr/bin/env bash
# Synthetic origins and process identities do not prove binary bytes or hardware execution.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_verify_ort_loader_trace.py"
