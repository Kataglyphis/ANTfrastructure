#!/usr/bin/env bash
# Proves native proof bindings and failures with doubles; no real consumer, registry or hardware is exercised.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/test-image-acceptance-ci.py"
