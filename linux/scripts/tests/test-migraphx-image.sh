#!/usr/bin/env bash
# Integration and child doubles do not prove an installed backend or image/GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_image_tests.py" "$@"
