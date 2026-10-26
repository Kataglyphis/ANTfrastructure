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

ci_image_python_require() {
  local caller="${1:?caller required}" docs="${2:-}" python="${3:-/opt/venv/bin/python3}"
  # The marker refuses a runnable host Python that is not the family image's pinned interpreter.
  if [ -z "${PYTHON_MAJOR_MINOR:-}" ] || [ ! -x "$python" ] ||
     ! (PREFLIGHT_PYTHON="$python"; preflight_python_require "$caller") >/dev/null 2>&1; then
    printf '%s runs in the family Linux image%s\n' "$caller" "${docs:+ ($docs)}" >&2
    return 2
  fi
  PREFLIGHT_PYTHON="$python"
  export PREFLIGHT_PYTHON
}

python_venv_executable() {
  local venv="$1" candidate
  for candidate in "$venv/bin/python" "$venv/Scripts/python.exe"; do
    if [ -x "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
  return 1
}
