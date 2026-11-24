#!/usr/bin/env bash
# Real Git fixtures and a full-proof double cannot prove actual Media builds, cache hits or GPU acceptance.
set -euo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/media_source_profile_tests.py" "$@"
