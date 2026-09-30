#!/usr/bin/env bash
# [--root <dir>] [file.py ...]: ruff, no imports run; E9,F63,F7,F82 fail, the rest is advisory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# Safe loader, never source; `:?` not `:-`, since a fallback is a second pin. docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
_core="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core"
if [ ! -f "${_core}/versions.env" ] || [ ! -f "${_core}/load-versions-env.sh" ]; then
  printf 'ERROR: %s\n' "01-core/versions.env or 01-core/load-versions-env.sh is missing beside ${_core} -- the ruff pin has nowhere to come from." >&2
  exit 1
fi
# shellcheck source=01-core/load-versions-env.sh
. "${_core}/load-versions-env.sh" && load_versions_env "${_core}/versions.env"
: "${RUFF_VERSION:?RUFF_VERSION is not set (01-core/versions.env parsed, but the key is gone from it)}"
RUFF_PIN="${RUFF_VERSION}"
GATE_SELECT="E9,F63,F7,F82"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
_RUFF_OUT="$(mktemp)"
trap 'rm -f "${_RUFF_OUT}"; rm -rf "${_EMB_DIR:-}"' EXIT

# Plain python3 is the Store stub on Git Bash, silently no-opping the helpers. docs/shared-script-libraries.md#python-interpreter-probe-01-corepython-probesh
# shellcheck source=01-core/python-probe.sh
. "${_core}/python-probe.sh"
preflight_python_require lint-python.sh || exit 1
_LINT_PY="${PREFLIGHT_PYTHON}"

# shellcheck source=01-core/lint-root.sh
. "${_core}/lint-root.sh"
lint_root_begin "${REPO_ROOT}" "$@" || exit 1
SCAN_ROOT="${LINT_ROOT_PATH}"
set -- ${LINT_ROOT_REST[@]+"${LINT_ROOT_REST[@]}"}

# Target set: first-party Python only
if [ "$#" -gt 0 ]; then
  PY_FILES=("$@")
elif [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
  # The same three exclusions the hub sweep carries, as git pathspecs.
  PY_FILES=()
  while IFS= read -r -d '' f; do
    PY_FILES+=("${SCAN_ROOT}/${f}")
  done < <(lint_root_tracked "${SCAN_ROOT}" '*.py' \
             ':!:*/node_modules/*' ':!:*/__pycache__/*' ':!:*/.venv/*')
else
  PY_FILES=()
  while IFS= read -r f; do
    PY_FILES+=("${f}")
  done < <(find docs/scripts linux/scripts linux/llm-stack linux/webserver \
             -name '*.py' -type f \
             -not -path '*/node_modules/*' -not -path '*/__pycache__/*' \
             -not -path '*/.venv/*' 2>/dev/null | sort)
fi
[ "${#PY_FILES[@]}" -gt 0 ] || err "No Python files found to lint under ${SCAN_ROOT}."

# Heredoc Python, hub's or consumer's, is invisible to ruff otherwise. docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs
if [ "$#" -eq 0 ]; then
  _EMB_DIR="$(mktemp -d)"
  _EMB_MAP="${_EMB_DIR}/.sources"
  _EMB_SH=()
  if [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
    while IFS= read -r -d '' f; do _EMB_SH+=("${SCAN_ROOT}/${f}"); done \
      < <(lint_root_tracked "${SCAN_ROOT}" '*.sh')
  else
    while IFS= read -r f; do _EMB_SH+=("${f}"); done \
      < <(find linux/scripts -name '*.sh' -type f; find linux/host-config/git-hooks -type f)
  fi
  # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
  if ${_LINT_PY} linux/scripts/extract_embedded_python.py "${_EMB_DIR}" \
       ${_EMB_SH[@]+"${_EMB_SH[@]}"} > "${_EMB_MAP}" 2>/dev/null; then
    while IFS= read -r f; do PY_FILES+=("${f}"); done \
      < <(find "${_EMB_DIR}" -name '*.py' -type f | sort)
  fi
fi

# Maps a probe__2.py:1: finding back to the shell file and its real line.
_name_sources() {
  # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
  ${_LINT_PY} - "${_EMB_MAP:-/dev/null}" "$1" <<'EMBPY'
import re
import sys

table = {}
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        for row in fh:
            tmp, _, where = row.rstrip("\n").partition("\t")
            if tmp and where:
                table[tmp] = where
except OSError:
    pass


def relabel(hit):
    where = table.get(hit.group(1))
    if where is None:
        return hit.group(0)
    exact = re.match(r"(.*):(\d+)$", where)
    if exact:
        return "%s:%d" % (exact.group(1), int(exact.group(2)) + int(hit.group(2)))
    return "%s line %s" % (where, hit.group(2))


ANSI = re.compile(r"\x1b\[[0-9;]*m")
NAMED = re.compile(r"(\S+\.py):(\d+)")
with open(sys.argv[2], encoding="utf-8") as fh:
    for line in fh:
        sys.stdout.write(NAMED.sub(relabel, ANSI.sub("", line)))
EMBPY
}

# ruff bootstrap: PATH copy preferred, else the pinned uvx
RUFF=()
if command -v ruff >/dev/null 2>&1; then
  RUFF=(ruff)
elif command -v uvx >/dev/null 2>&1; then
  RUFF=(uvx "ruff@${RUFF_PIN}")
else
  err "neither ruff nor uvx found — install uv (repo standard) or ruff"
fi

echo "== python lint under ${SCAN_ROOT}: ${#PY_FILES[@]} file(s), ruff via '${RUFF[*]}' =="

# Gate pass — real-error classes only, hard-fails.
if ! "${RUFF[@]}" check --quiet --select "${GATE_SELECT}" "${PY_FILES[@]}" > "${_RUFF_OUT}" 2>&1; then
  _name_sources "${_RUFF_OUT}"
  echo ""
  err "python gate pass failed (${GATE_SELECT}: syntax errors / undefined names / invalid asserts)"
fi
echo "gate pass (${GATE_SELECT}): clean"

# Advisory pass — full default ruleset, informational only.
echo ""
echo "-- advisory pass (full default ruleset; does not fail the gate) --"
if "${RUFF[@]}" check "${PY_FILES[@]}" > "${_RUFF_OUT}" 2>&1; then
  echo "advisory pass: clean"
else
  _name_sources "${_RUFF_OUT}"
  echo ""
  echo "ADVISORY: findings above are informational (adoption ramp — tighten by"
  echo "promoting codes into GATE_SELECT once addressed; do not churn files"
  echo "just to satisfy style rules)."
fi
exit 0
