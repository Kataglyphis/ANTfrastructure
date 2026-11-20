#!/usr/bin/env bash
# Synthetic producer/engine cases prove local-mode refusals and shared consumer policies, not actual FINAL images or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/image_acceptance_local_tests.py" "$@"
