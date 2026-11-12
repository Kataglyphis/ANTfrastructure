#!/usr/bin/env bash
# Explicit transport/build doubles and real SHA256 checks do not build vendor libraries or accept an image.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_stack_tests.py"
