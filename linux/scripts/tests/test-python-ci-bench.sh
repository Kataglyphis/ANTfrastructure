#!/usr/bin/env bash
# ci_tests.sh's benchmark leg; not covered: what the benchmarks measure or how long they take.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
# shellcheck source=linux/scripts/tests/python-ci-fixture.sh
source "${TESTS_DIR}/python-ci-fixture.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"

_work="$(mktemp -d)"; trap 'rm -rf "${_work}"' EXIT
python_ci_tests_fixture "${_work}" "${SCRIPTS}" || exit 1
REC="${CALLS}"
# The report verifier has its own suite; here it accepts, so only the benchmark step decides the leg.
printf 'import sys\nsys.exit(0)\n' > "${TREE}/02-toolchain/python/verify-test-reports.py"
# Every uv effect is recorded; `pytest bench/` fails on FAIL_BENCH.
cat >> "${TREE}/02-toolchain/python/ci-common.sh" <<'CI_COMMON'
derive_package_name() { printf 'pkg'; }
uv_venv_create() { :; }
uv_run() {
  echo "run $* in ${PWD}" >> "${REC}"
  [ "$1 ${2:-}" != "pytest bench/" ] || [ -z "${FAIL_BENCH:-}" ]
}
uv_sync_project() { echo sync >> "${REC}"; }
uv_cache_seed_restore() { :; }
CI_COMMON
python_ci_venv_noops

_driver() {
  : > "${REC}"
  env -u PY_VERSIONS -u EXPERIMENTAL_PYTHON_VERSIONS REC="${REC}" FIXTURE_WS="${WS}" \
    GIT_CONFIG_GLOBAL="${_work}/gitconfig" CI_TESTS_LOG_FILE="${_work}/tests.log" \
    bash "${TREE}/02-toolchain/python/ci_tests.sh" "$@" > "${_work}/out" 2>&1
}

t_case "a missing bench/ skips the benchmark suite with a visible line"
t_assert_ok _driver
t_assert_contains "$(cat "${_work}/out")" "No bench/ directory; benchmark suite skipped"
t_assert_fails grep -q -F -e 'run pytest bench/' "${REC}"

t_case "a present bench/ runs as pytest bench/ from the workspace root"
mkdir -p "${WS}/bench"
t_assert_ok _driver
t_assert_contains "$(cat "${REC}")" "run pytest bench/ in ${WS}"

t_case "a failing bench/ fails the leg"
FAIL_BENCH=1 t_assert_fails _driver
t_assert_contains "$(cat "${_work}/out")" "pytest bench/ exited 1"

t_case "no switch is left to turn the gate off"
t_assert_no_grep "${TESTS_DIR}/../02-toolchain/python/ci_tests.sh" 'PYTHON_BENCH_GATE'
t_assert_no_grep "${TESTS_DIR}/../../../.github/workflows/python-ci-linux.yml" 'bench-gate'
t_assert_no_grep "${TESTS_DIR}/../../../.github/workflows/python-ci-linux.yml" 'PYTHON_BENCH_GATE'

t_summary
