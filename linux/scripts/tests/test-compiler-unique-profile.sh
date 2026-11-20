#!/usr/bin/env bash
# File and proof doubles grade planner boundaries, not actual compiler or cache results.
set -euo pipefail
python3 "${BASH_SOURCE[0]%/*}/compiler_unique_profile_tests.py"
