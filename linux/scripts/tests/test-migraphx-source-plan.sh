#!/usr/bin/env bash
# Extracted source plans test fail-closed policy; they do not configure or run the real backend.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_source_plan_tests.py"
