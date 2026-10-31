#!/usr/bin/env bash
# Tests locked package bytes without a network, GPU, or package build.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 "$repo/shared/python/tests/test_verify_locked_files.py"
