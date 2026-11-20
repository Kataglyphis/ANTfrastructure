#!/usr/bin/env bash
# Synthetic wheel/hash failures and fake uv children do not prove NumPy, source builds or target execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/python-proof-fixture.sh"
t_private_tmpdir
fixture="$(t_mktemp)"
t_fake_elf "${fixture}" 62
export T_FT_ELF="${fixture}"
t_python_fixture_suite "${TESTS_DIR}/../06-packaging/free-threaded-probe-deps.py" "${TESTS_DIR}/free_threaded_probe_deps_tests.py"
t_summary
