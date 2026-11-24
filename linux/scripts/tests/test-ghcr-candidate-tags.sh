#!/usr/bin/env bash
# Selection over a fixed listing only; the live registry and the owner-approved deletion stay outside.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/ghcr_candidate_tags_tests.py" "$@"
