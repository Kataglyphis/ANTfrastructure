#!/usr/bin/env bash
# Mocked lifecycle fixtures prove refusal and cleanup policies, not real systemd, container, build or GPU behavior.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/seal_command_unit_tests.py" "$@"
