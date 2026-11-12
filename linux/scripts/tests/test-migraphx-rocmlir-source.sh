#!/usr/bin/env bash
# Source, notice and command-double tests do not compile vendor libraries or prove binary licence closure.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_rocmlir_source_tests.py"
