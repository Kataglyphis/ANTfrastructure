#!/usr/bin/env bash
# Offline refusals only; a real registry, GitHub run and ARM64 device stay required.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/windows_arm64_acceptance_tests.py" "$@"
