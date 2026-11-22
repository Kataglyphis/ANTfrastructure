#!/usr/bin/env bash
# File fixtures and explicit Git/proof doubles cannot prove actual image, cache or GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/gpu_source_profile_tests.py" "$@"
