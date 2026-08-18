#!/usr/bin/env bash
# Tests for 01-core/chain-lifecycle.sh — the orchestrator-lifecycle primitives
# shared by build-cross-chain.sh and stop-cross-chain.sh (Batch 5 / O1+O2):
# canonical CROSS_RUN_ID generation, the well-known pidfile path, and the
# child-subtree termination walk.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"
source "${CORE_DIR}/chain-lifecycle.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---------------------------------------------------------------------------
# O2: run-id generation.
t_case "cross_run_id_generate returns a non-empty timestamped id"
rid="$(cross_run_id_generate)"
t_assert_contains "${rid}" "-" "id must join a timestamp and a random suffix"
# Shape: YYYYMMDD-HHMMSS-<hex/rand>  (leading 8-digit date).
case "${rid}" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-*) t_assert_eq "1" "1" ;;
  *) t_assert_eq "YYYYMMDD-..." "${rid}" "id must start with an 8-digit date" ;;
esac

t_case "cross_run_id_generate is unique across calls"
a="$(cross_run_id_generate)"; b="$(cross_run_id_generate)"
if [ "${a}" != "${b}" ]; then t_assert_eq "1" "1"; else
  t_assert_eq "distinct" "same" "two generated ids collided: ${a}"
fi

t_case "cross_run_id_ensure sets, exports, and is idempotent"
unset CROSS_RUN_ID || true
cross_run_id_ensure
first="${CROSS_RUN_ID}"
t_assert_ok test -n "${first}"
# exported?
t_assert_contains "$(export -p | grep 'CROSS_RUN_ID' || true)" "CROSS_RUN_ID" "must be exported"
cross_run_id_ensure
t_assert_eq "${first}" "${CROSS_RUN_ID}" "a second ensure must not regenerate"

t_case "cross_run_id_ensure honors a pre-set CROSS_RUN_ID"
CROSS_RUN_ID="my-custom-run"
cross_run_id_ensure
t_assert_eq "my-custom-run" "${CROSS_RUN_ID}" "a caller override must win"
unset CROSS_RUN_ID || true

# ---------------------------------------------------------------------------
# O2: pidfile path.
t_case "cross_chain_pidfile_path honors CROSS_CHAIN_PIDFILE"
t_assert_eq "/run/mychain.pid" \
  "$(CROSS_CHAIN_PIDFILE=/run/mychain.pid cross_chain_pidfile_path)"

t_case "cross_chain_pidfile_path defaults under TMPDIR"
t_assert_eq "/custom/tmp/kata-cross-chain.pid" \
  "$(TMPDIR=/custom/tmp CROSS_CHAIN_PIDFILE= cross_chain_pidfile_path)"

# ---------------------------------------------------------------------------
# O1: child-subtree termination. Launch a root process that itself backgrounds a
# leaf sleep, then TERM the subtree of the root and confirm the leaf dies while
# the walk never targets the root's PARENT (this test process).
t_case "chain_terminate_descendants TERMs the descendant subtree"
bash -c 'sleep 30 & echo $! > "'"${workdir}"'/leaf.pid"; wait' &
root=$!
# Give the child time to spawn its leaf and record the pid.
_waited=0
while [ ! -s "${workdir}/leaf.pid" ] && [ "${_waited}" -lt 20 ]; do sleep 0.1; _waited=$((_waited + 1)); done
leaf="$(cat "${workdir}/leaf.pid" 2>/dev/null || true)"
t_assert_ok test -n "${leaf}"
chain_terminate_descendants TERM "${root}"
# The leaf (a descendant of root) must terminate; wait briefly for signal.
_waited=0
while kill -0 "${leaf}" 2>/dev/null && [ "${_waited}" -lt 25 ]; do sleep 0.1; _waited=$((_waited + 1)); done
t_assert_fails kill -0 "${leaf}"
kill "${root}" 2>/dev/null || true
wait "${root}" 2>/dev/null || true

t_summary
