#!/usr/bin/env bash
# Filesystem and child-process controls do not prove compiler-cache hits, production builds or concurrent-writer authentication.
set -euo pipefail
"${PREFLIGHT_PYTHON:-python3}" "$(dirname "${BASH_SOURCE[0]}")/mutation_workspace_tests.py" "$@"
