#!/usr/bin/env bash
# Transport fixtures prove preserved sources and cleanup policy, not container builds or GPU execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/git-fixture-env.sh"
work="$(t_mktemp -d)" || exit 1
plant() {
  local target="$1"
  mkdir -p "${target}/linux/scripts/isolated-preflight" "${target}/linux/scripts/01-core" || return
  cp "${TESTS_DIR}/../isolated-preflight/bootstrap.sh" "${target}/linux/scripts/isolated-preflight/" || return
  cp "${TESTS_DIR}/../01-core/load-versions-env.sh" "${target}/linux/scripts/01-core/" || return
  cp "${TESTS_DIR}/../01-core/versions.env" "${target}/linux/scripts/01-core/" || return
  printf 'old\n' > "${target}/marker"
}
fixture="$(t_consumer_fixture "${work}" plant isolated)" || exit 1
revision="$(git -C "${fixture}" rev-parse HEAD)" || exit 1
printf 'new\n' > "${fixture}/marker"
t_git_commit "${fixture}" || exit 1
printf 'dirty\n' > "${fixture}/marker"
t_case "persistent proof tools preserve sources, raw results and owned-container boundaries"
t_needs "POSIX fixture executables" t_posix_python
t_assert_ok python3 "${TESTS_DIR}/proof_workflow_tests.py" "${TESTS_DIR}/.." "${fixture}" "${revision}"
t_summary
