#!/usr/bin/env bash
# Proves release identity and collision checks without writing a GitHub release.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 -I "$root/shared/python/tests/test_attach_release_assets.py"
python3 -I "$root/shared/python/tests/test_attach_release_assets_mutations.py"
