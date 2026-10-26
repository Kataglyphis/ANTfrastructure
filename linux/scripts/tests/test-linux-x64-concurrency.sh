#!/usr/bin/env bash
# GitHub schedules runs remotely; this suite guards the local concurrency expression, not queue execution.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/scripts/tests/workflow-lane-fixture.sh
source "${TESTS_DIR}/workflow-lane-fixture.sh"
workflow_lane_fixture_init .github/workflows/linux-x64.yml preflight mutations "${PREFLIGHT_PYTHON:-python3}" || exit 1

t_case "develop keeps its running proof while other refs may cancel stale runs"
t_assert_eq "\${{ github.ref != 'refs/heads/develop' }}" \
  "$(_q "V.value(V.value(lane, 'concurrency'), 'cancel-in-progress')")" \
  "develop must finish its eight mutation shards before the next pending push runs"

t_case "concurrency groups remain separated by ref"
t_assert_eq "linux-x64-\${{ github.ref }}" \
  "$(_q "V.value(V.value(lane, 'concurrency'), 'group')")" \
  "a develop push must not queue behind a main or PR run"

t_summary
