#!/usr/bin/env bash
# Measures one checkout into logs/code-quality/ and grades it against a baseline; it runs no tests or builds.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${script_dir}/quality_report.py" "$@"
