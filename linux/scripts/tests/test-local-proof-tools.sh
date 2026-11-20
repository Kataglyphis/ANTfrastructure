#!/usr/bin/env bash
# Host doubles and receipt fixtures do not build images, reclaim real storage or prove hardware acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/local_proof_tool_tests.py" "$@"
