#!/usr/bin/env bash
# gates.sh - "run every gate, then fail once" for shell drivers.

# Three repos re-invented this independently (GATE_FAILURES, FAILED=1,
# $script:GateFailures): every tool RUNS even after an earlier one fails, and
# the exit status is decided once, at the end. Stopping at the first failure
# costs one push per finding.
#
#   gate_reset [label]      start a batch (clears the counters)
#   run_gate <name> cmd...  run one gate; a non-zero exit is RECORDED
#   assert_gates            0 when all passed; 1 naming every failure

# `|| FAILED=1` RECORDS a failure, it does not swallow one - but only because
# assert_gates re-raises it. run_gate without a closing assert_gates is
# suppression wearing a costume, so assert_gates fails when NO gate ran at all:
# an aggregator that graded nothing must not report green.
# docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

[ -n "${_GATES_SH_LOADED:-}" ] && return 0
_GATES_SH_LOADED=1

_GATE_FAILURES=()
_GATE_RAN=0
_GATE_LABEL="gates"

gate_reset() {
  _GATE_FAILURES=()
  _GATE_RAN=0
  _GATE_LABEL="${1:-gates}"
}

# run_gate <name> <command> [args...]
# Never returns non-zero for a FAILING gate - that is the point; it returns 2
# only for a caller error (no command), which is a bug, not a finding.
run_gate() {
  local name="${1:?gate name required}"
  shift
  if [ "$#" -eq 0 ]; then
    printf 'run_gate: gate "%s" was given no command to run.\n' "${name}" >&2
    return 2
  fi
  _GATE_RAN=$((_GATE_RAN + 1))
  printf '\n== %s ==\n' "${name}"
  local status=0
  "$@" || status=$?
  if [ "${status}" -eq 0 ]; then
    printf '== %s: ok ==\n' "${name}"
    return 0
  fi
  printf '== %s: FAILED (exit %d) ==\n' "${name}" "${status}" >&2
  _GATE_FAILURES+=("${name}")
  return 0
}

assert_gates() {
  if [ "${_GATE_RAN}" -eq 0 ]; then
    printf '%s: no gate ran - refusing to report green over nothing.\n' "${_GATE_LABEL}" >&2
    return 1
  fi
  if [ "${#_GATE_FAILURES[@]}" -gt 0 ]; then
    printf '%s FAILED (%d of %d): %s\n' \
      "${_GATE_LABEL}" "${#_GATE_FAILURES[@]}" "${_GATE_RAN}" "${_GATE_FAILURES[*]}" >&2
    return 1
  fi
  printf '%s OK (%d gate(s))\n' "${_GATE_LABEL}" "${_GATE_RAN}"
  return 0
}
