#!/usr/bin/env bash
# Host staging and dispatch controls do not prove BuildKit reuse or final image acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/script_context_tests.py" "$@"
