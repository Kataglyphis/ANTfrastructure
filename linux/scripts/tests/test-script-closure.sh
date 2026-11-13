#!/usr/bin/env bash
# Deterministic selected-file staging does not establish BuildKit hits, builds or runtime acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/script_closure_tests.py" "$@"
