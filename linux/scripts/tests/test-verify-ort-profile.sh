#!/usr/bin/env bash
# Profile events must establish operator execution on the selected provider.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_verify_ort_profile.py"
# Isolated mode, as consumers run it: the sibling fixture must still import.
python3 -I "$root/shared/python/tests/test_verify_ort_profile.py"
