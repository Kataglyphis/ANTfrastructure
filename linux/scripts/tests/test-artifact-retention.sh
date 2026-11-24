#!/usr/bin/env bash
# The hub workflows' declared retention only; actual GitHub expiry is not exercised.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/artifact_retention_tests.py" "$@"
