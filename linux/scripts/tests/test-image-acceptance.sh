#!/usr/bin/env bash
# Exercises receipt refusal and exact promotion bytes; it does not contact GHCR or build consumers.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/test-image-acceptance.py"
