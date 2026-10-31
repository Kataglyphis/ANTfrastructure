#!/usr/bin/env bash
# No GPU execution, receipt authentication or GitHub artifact service is exercised.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_stage_gpu_artifact.py"
python3 "$root/shared/python/tests/test_clean_host_gpu_receipt.py"
