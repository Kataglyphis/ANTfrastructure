#!/usr/bin/env bash
# Run every gate, then fail once. docs/shared-script-libraries.md#gate-aggregation-01-coregatessh

# A batch where nothing ran is never green, and a skip is red unless assert_gates gets --tolerate-skips.

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

# run_gate <name> <cmd...>: returns 0 even when the gate fails (assert_gates re-raises), 2 on caller error.
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
  # Subshell: helpers that fail via err() (exit 1) would otherwise kill the driver before assert_gates.
  ( "$@" ) || status=$?
  if [ "${status}" -eq 0 ]; then
    printf '== %s: ok ==\n' "${name}"
    return 0
  fi
  printf '== %s: FAILED (exit %d) ==\n' "${name}" "${status}" >&2
  _GATE_FAILURES+=("${name}")
  return 0
}

# gate_skip <name> [reason...]: a skip without a reason reads like a quietly deleted gate.
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
