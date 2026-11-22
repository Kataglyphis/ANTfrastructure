#!/usr/bin/env bash
# Real pinned-source slices check pooling policy; typed doubles do not establish SDK or GPU numerics.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_padding_tests.py"
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_padding_preparation_tests.py"
