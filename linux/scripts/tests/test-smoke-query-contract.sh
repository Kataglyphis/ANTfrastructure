#!/usr/bin/env bash
# Stubbed queries cover pipeline verdicts and parse-time bindings, not real media binaries or filesystem races.
set -eu
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${tests_dir}/smoke-query-contract-tests.py" "${1:-${tests_dir}/../06-packaging/smoke-media.sh}"
