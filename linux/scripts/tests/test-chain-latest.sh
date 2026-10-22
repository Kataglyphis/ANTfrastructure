#!/usr/bin/env bash
# chain-latest.sh: the plan carries the profile into the command, and a start refuses before it touches systemd (CON-simplicity).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CHAIN="${TESTS_DIR}/../chain-latest.sh"
_out="$(mktemp)"
trap 'rm -f "${_out}"' EXIT

t_case "the plan names the profile's arches, stages and parallelism, and the command that would run"
bash "${CHAIN}" --plan > "${_out}" 2>&1
t_assert_contains "$(cat "${_out}")" "MAX_PARALLEL_ARCHS=3"
t_assert_contains "$(cat "${_out}")" "BUILD_MEM_DIVISOR=18 (min(arches, 3) x PAR_INTRA_STEP_BUDGET"
t_assert_contains "$(cat "${_out}")" "bash linux/scripts/build-cross-chain.sh --target-arches amd64,arm64,riscv64 --parallel-archs --from-stage base"

t_case "a start refuses below the disk gate, before any unit is touched"
CHAIN_MIN_FREE_GB=999999 bash "${CHAIN}" > "${_out}" 2>&1; rc=$?
t_assert_eq "4" "${rc}"
t_assert_contains "$(cat "${_out}")" "below the 999999G gate; not starting"

t_case "a start refuses below the memory gate"
CHAIN_MIN_MEM_GB=999999 bash "${CHAIN}" > "${_out}" 2>&1; rc=$?
t_assert_eq "4" "${rc}"
t_assert_contains "$(cat "${_out}")" "below the 999999G gate; not starting"

t_case "an unknown argument is a usage error"
bash "${CHAIN}" --bogus > "${_out}" 2>&1; rc=$?
t_assert_eq "2" "${rc}"

t_summary
