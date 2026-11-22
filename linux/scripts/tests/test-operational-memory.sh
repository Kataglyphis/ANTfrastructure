#!/usr/bin/env bash
# Synthetic services and files prove refusal paths, not live-host absence or protection from other writers.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=python-proof-fixture.sh
source "${TESTS_DIR}/python-proof-fixture.sh"
PYTHONPATH="${TESTS_DIR}/..${PYTHONPATH:+:$PYTHONPATH}" \
  t_python_fixture_suite "${TESTS_DIR}/../append-operational-memory.py" "${TESTS_DIR}/operational_memory_tests.py"
t_summary
