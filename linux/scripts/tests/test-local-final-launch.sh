#!/usr/bin/env bash
# Synthetic unit/engine fixtures and receipt schemas cannot prove real FINAL consumers or hardware.
set -euo pipefail
python3 -B "$(dirname "$0")/local_final_launch_tests.py"
