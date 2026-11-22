#!/usr/bin/env bash
# Synthetic compiler responses check refusal and collection, not installed binaries, ELF ISA or GPU inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_private_tmpdir
t_python_fixture_suite "${1:-${TESTS_DIR}/../06-packaging/probe-compiler-defaults.py}" "${TESTS_DIR}/compiler_defaults_tests.py"
t_summary
