#!/usr/bin/env bash
# Replay protocol doubles do not run systemd, containers, vendor compilers or actual quality gates.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/migraphx_source_launcher_tests.py"
