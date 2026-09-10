#!/usr/bin/env bash
# gates.sh - "run every gate, then fail once" for shell drivers.

# Three repos re-invented this independently (GATE_FAILURES, FAILED=1,
# $script:GateFailures): every tool RUNS even after an earlier one fails, and
# the exit status is decided once, at the end. Stopping at the first failure
# costs one push per finding.
#
#   gate_reset [label]      start a batch (clears the counters)
#   run_gate <name> cmd...  run one gate; a non-zero exit is RECORDED
#   gate_skip <name> [why]  record a gate that COULD NOT run, and why
#   assert_gates [--tolerate-skips]
#                           0 when all passed; 1 naming every failure or skip

# `|| FAILED=1` RECORDS a failure, it does not swallow one - but only because
# assert_gates re-raises it. run_gate without a closing assert_gates is
# suppression wearing a costume, so assert_gates fails when NO gate ran at all:
# an aggregator that graded nothing must not report green.
# docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

# THE THIRD BUCKET (2026-09-09). A gate can also be UNRUNNABLE - its tool is not
# installed - which is neither a pass nor a failure. Counting it as a pass is
# the suppression this file exists to prevent, so gate_skip records it instead.
# A skipped gate never makes an otherwise-empty batch green, and it is RED BY
# DEFAULT: tolerating one is an explicit, greppable --tolerate-skips, because
# "allowed to fail" is exactly what the fleet rule forbids as a default.
# docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

[ -n "${_GATES_SH_LOADED:-}" ] && return 0
_GATES_SH_LOADED=1

_GATE_FAILURES=()
_GATE_SKIPPED=()
_GATE_RAN=0
_GATE_LABEL="gates"

gate_reset() {
  _GATE_FAILURES=()
  _GATE_SKIPPED=()
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
  # SUBSHELL, and not a bare "$@": upstream check helpers report failure
  # with err(), which is `exit 1`. Called directly that exit unwinds THIS
  # shell, so the driver dies before assert_gates - every finding already
  # recorded is lost and the batch never prints a verdict. The subshell
  # contains it, so "run every gate, then fail once" holds for those too.
  ( "$@" ) || status=$?
  if [ "${status}" -eq 0 ]; then
    printf '== %s: ok ==\n' "${name}"
    return 0
  fi
  printf '== %s: FAILED (exit %d) ==\n' "${name}" "${status}" >&2
  _GATE_FAILURES+=("${name}")
  return 0
}

# gate_skip <name> [reason...]
# For a gate that was NOT run and therefore graded nothing. The reason is part
# of the record on purpose: "skipped" without one is indistinguishable from a
# gate somebody quietly deleted.
gate_skip() {
  local name="${1:?gate name required}"
  shift
  local reason="$*"
  _GATE_SKIPPED+=("${name}")
  if [ -n "${reason}" ]; then
    printf '\n== %s: SKIPPED (%s) ==\n' "${name}" "${reason}" >&2
  else
    printf '\n== %s: SKIPPED ==\n' "${name}" >&2
  fi
  return 0
}

assert_gates() {
  local tolerate_skips=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tolerate-skips) tolerate_skips=1; shift ;;
      *)
        printf 'assert_gates: unknown argument "%s" (expected --tolerate-skips)\n' "$1" >&2
        return 2
        ;;
    esac
  done

  local skipped=0
  if [ "${#_GATE_SKIPPED[@]}" -gt 0 ]; then
    skipped="${#_GATE_SKIPPED[@]}"
    printf '%s: %d gate(s) SKIPPED, and graded nothing: %s\n' \
      "${_GATE_LABEL}" "${skipped}" "${_GATE_SKIPPED[*]}" >&2
  fi

  if [ "${_GATE_RAN}" -eq 0 ]; then
    if [ "${skipped}" -gt 0 ]; then
      printf '%s: no gate ran - all %d were skipped, so there is no result to report.\n' \
        "${_GATE_LABEL}" "${skipped}" >&2
    else
      printf '%s: no gate ran - refusing to report green over nothing.\n' "${_GATE_LABEL}" >&2
    fi
    return 1
  fi

  if [ "${#_GATE_FAILURES[@]}" -gt 0 ]; then
    printf '%s FAILED (%d of %d): %s\n' \
      "${_GATE_LABEL}" "${#_GATE_FAILURES[@]}" "${_GATE_RAN}" "${_GATE_FAILURES[*]}" >&2
    return 1
  fi

  if [ "${tolerate_skips}" -eq 0 ] && [ "${skipped}" -gt 0 ]; then
    printf '%s FAILED: %d gate(s) skipped and a skip is not tolerated here: %s\n' \
      "${_GATE_LABEL}" "${skipped}" "${_GATE_SKIPPED[*]}" >&2
    printf '%s: pass --tolerate-skips to assert_gates if a skip is acceptable, and say why.\n' \
      "${_GATE_LABEL}" >&2
    return 1
  fi

  if [ "${skipped}" -gt 0 ]; then
    printf '%s OK (%d gate(s), %d skipped)\n' "${_GATE_LABEL}" "${_GATE_RAN}" "${skipped}"
  else
    printf '%s OK (%d gate(s))\n' "${_GATE_LABEL}" "${_GATE_RAN}"
  fi
  return 0
}
