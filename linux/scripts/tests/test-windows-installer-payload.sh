#!/usr/bin/env bash
# Unit and mutation tests only; no Windows installer or GPU execution occurs here.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 -I "$repo/shared/python/tests/test_windows_installer_payload.py"
python3 -I "$repo/shared/python/tests/test_windows_installer_payload_mutations.py"
