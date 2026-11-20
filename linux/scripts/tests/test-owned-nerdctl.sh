#!/usr/bin/env bash
# Fake engine/exec controls prove ownership and status transport, not actual containers, registry bytes or inference.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/owned_nerdctl_tests.py" "$@"
