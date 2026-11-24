#!/usr/bin/env bash
# The workflow's declared packages and guards only; a real prune needs the registry and the PAT.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/ghcr_cleanup_workflow_tests.py" "$@"
