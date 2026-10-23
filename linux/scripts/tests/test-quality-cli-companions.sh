#!/usr/bin/env bash
# Cold copied-library imports check the required CLI companion and retry state, not tool execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
WORK="$(mktemp -d '/tmp/ant-quality companion.XXXXXXXX')"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/lib" "${WORK}/01-core"
cp "${TESTS_DIR}/../lib/log-bootstrap.sh" "${WORK}/lib/"
cp "${TESTS_DIR}/../01-core/tool-checks.sh" "${TESTS_DIR}/../01-core/logging.sh" "${WORK}/01-core/"
for library in code-quality coverage; do
  t_case "${library}: a missing companion fails and a restored companion allows retry"
  cp "${TESTS_DIR}/../lib/${library}.sh" "${WORK}/lib/"
  rm -f "${WORK}/lib/cli-value-options.sh"
  output="$(bash -uc '
    source "$1" 2>/dev/null
    printf "FIRST=%s\n" "$?"
    cp "$2" "$3"
    source "$1"
    printf "SECOND=%s\n" "$?"
    declare -F append_cli_nonempty_args >/dev/null
    printf "HELPER=%s\n" "$?"
  ' _ "${WORK}/lib/${library}.sh" "${TESTS_DIR}/../lib/cli-value-options.sh" "${WORK}/lib/cli-value-options.sh" 2>&1)"
  t_assert_eq $'FIRST=1\nSECOND=0\nHELPER=0' "${output}"
done
t_summary
