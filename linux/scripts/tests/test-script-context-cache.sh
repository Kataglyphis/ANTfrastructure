#!/usr/bin/env bash
# Fixture controls do not establish real BuildKit or compiler/image acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/script_context_cache_tests.py"
