#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 -I "$root/shared/python/tests/test_resolve_gpu_producer_receipt.py"
node "$root/shared/python/tests/test_resolve_gpu_producer_action.js"
python3 -I "$root/shared/python/tests/test_resolve_gpu_producer_mutations.py"
python3 -I "$root/shared/python/tests/test_attach_release_assets.py"
python3 -I "$root/shared/python/tests/test_attach_release_assets_mutations.py"
