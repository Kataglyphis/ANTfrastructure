#!/usr/bin/env bash
# Prove package dependencies fail closed on incomplete ELF or ldconfig evidence.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
for tool in cc readelf ldconfig dpkg patchelf; do t_skip_unless "${tool}" command -v "${tool}"; done
t_case 'real ELF, static ELF and corrupted dependency evidence'
t_assert_ok python3 "${TESTS_DIR}/test-python-deb-depends.py"
t_summary
