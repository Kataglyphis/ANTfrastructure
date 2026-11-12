#!/usr/bin/env bash
# Fixture packages prove the external transport gates, not the real CK SDK or GPU.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_ck_consumer_tests.py" "$@"
