#!/usr/bin/env bash
# python3 may be the Windows Store stub, so verify first. docs/shared-script-libraries.md#python-interpreter-probe-01-corepython-probesh

[ -n "${_PYTHON_PROBE_SH_LOADED:-}" ] && return 0
_PYTHON_PROBE_SH_LOADED=1

# Callers expand PREFLIGHT_PYTHON unquoted: it may be a command line like "uv run --no-project python".
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
