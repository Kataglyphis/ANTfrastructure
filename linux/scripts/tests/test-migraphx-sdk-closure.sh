#!/usr/bin/env bash
# Isolated real CMake config controls prove package-resolution policy, not SDK binaries or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_sdk_closure_tests.py"
