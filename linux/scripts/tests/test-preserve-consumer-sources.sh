#!/usr/bin/env bash
# Real local Git controls prove copies and refusals, not source authentication, build outputs or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/consumer_source_preservation_tests.py" "$@"
