#!/usr/bin/env bash
# Profile events must establish operator execution on the selected provider.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_verify_ort_profile.py"
