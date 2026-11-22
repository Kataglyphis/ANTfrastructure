#!/usr/bin/env bash
# Command and native fixtures exercise refusals, not actual runtime builds, registry availability, licences or GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/runtime_launch_tests.py" "$@"
