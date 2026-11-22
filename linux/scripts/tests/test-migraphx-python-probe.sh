#!/usr/bin/env bash
# Module doubles prove refusal/lifecycle verdicts; they do not compile, import or accept a genuine backend.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_python_probe_tests.py"
