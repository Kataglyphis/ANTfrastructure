#!/usr/bin/env bash
# Temporary trees and filesystem doubles prove refusal and retention; they do not reclaim real host storage or prove builds.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
t_needs "POSIX file and inode fixtures" t_posix_python
work="$(t_mktemp -d)" || exit 1
plant() {
  mkdir -p "$1/quality" || return
  printf 'fixture rules\n' > "$1/AGENTS.md"
  printf 'fixture lock\n' > "$1/quality/uv.lock"
  printf 'quality/.venv/\n' > "$1/.gitignore"
}
fixture="$(t_consumer_fixture "${work}" plant quality-venv)" || exit 1
t_case "quality environments retain bytes and refuse unsafe source or destination inputs"
t_assert_rc 0 python3 "${TESTS_DIR}/quality_venv_relocation_tests.py" "${TESTS_DIR}/../../host-config/relocate-quality-venv.py" "${fixture}"
t_summary
