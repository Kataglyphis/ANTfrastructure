#!/usr/bin/env bash
# Receipt binding fixtures exercise no GPU or GitHub service.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_gpu_artifact_receipt.py"
python3 -I "$root/shared/python/tests/test_windows_installer_payload.py"
python3 -I "$root/shared/python/tests/test_windows_clean_gpu_receipt.py"
node "$root/shared/python/tests/test_windows_clean_gpu_action.js"
python3 -I "$root/shared/python/tests/test_windows_installer_payload_mutations.py"
