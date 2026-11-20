#!/usr/bin/env bash
# Protocol doubles test source-unit isolation and raw failures, not SDK configuration or real engine cleanup.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_configure_launcher_tests.py"
