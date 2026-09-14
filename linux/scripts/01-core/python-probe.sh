#!/usr/bin/env bash
# python-probe.sh - one owner for "is there a working Python here?"
# Plain python3 is NOT trusted: on Windows Git Bash it is the Microsoft Store
# stub, which prints an install hint and exits non-zero. preflight.sh probes a
# candidate list and exports PREFLIGHT_PYTHON; a gate run standalone inherits
# nothing, so it verifies before use instead of dying inside its Python step.
# docs/shared-script-libraries.md#python-interpreter-probe-01-corepython-probesh

[ -n "${_PYTHON_PROBE_SH_LOADED:-}" ] && return 0
_PYTHON_PROBE_SH_LOADED=1

# preflight_python_require <caller> -> 0 with PREFLIGHT_PYTHON exported when it
# (or, unset, python3) runs `-c pass`; 1 naming the caller and the knob otherwise.
# Callers expand PREFLIGHT_PYTHON UNQUOTED, as preflight.sh does: the value may
# be a command line, which is the very hint the failure message gives.
preflight_python_require() {
  local py="${PREFLIGHT_PYTHON:-python3}"
  # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
  if ${py} -c 'pass' >/dev/null 2>&1; then
    PREFLIGHT_PYTHON="${py}"
    export PREFLIGHT_PYTHON
    return 0
  fi
  printf '%s: no working Python (tried %s).\n' "${1:-python-probe}" "${py}" >&2
  printf 'Set PREFLIGHT_PYTHON, e.g. PREFLIGHT_PYTHON="uv run --no-project python"\n' >&2
  return 1
}
