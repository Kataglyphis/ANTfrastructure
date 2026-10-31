#!/usr/bin/env bash
# Receipt binding fixtures exercise no GPU or GitHub service.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$root/shared/python/tests/test_gpu_artifact_receipt.py"
