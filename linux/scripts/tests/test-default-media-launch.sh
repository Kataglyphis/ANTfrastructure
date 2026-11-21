#!/usr/bin/env bash
# Synthetic receipt callers keep real canonical flags and refusal controls; they do not build images or prove parent authenticity.
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$tests/default_media_launch_tests.py" "$@"
python3 "$tests/normal_stage_tests.py" "$@"
python3 "$tests/media_handoff_tests.py" "$@"
