#!/usr/bin/env bash
# Default hub sweeps reject unused bindings; named roots and explicit targets keep the advisory tier.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# Safe loader, never source; `:?` not `:-`, since a fallback is a second pin. docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
_core="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core"
if [ ! -f "${_core}/tool-pins.env" ] || [ ! -f "${_core}/load-versions-env.sh" ]; then
  printf 'ERROR: %s\n' "01-core/tool-pins.env or 01-core/load-versions-env.sh is missing beside ${_core} -- the ruff pin has nowhere to come from." >&2
  exit 1
fi
# shellcheck source=01-core/load-versions-env.sh
. "${_core}/load-versions-env.sh" && load_versions_env "${_core}/tool-pins.env"
: "${RUFF_VERSION:?RUFF_VERSION is not set (01-core/tool-pins.env parsed, but the key is gone from it)}"
RUFF_PIN="${RUFF_VERSION}"
GATE_SELECT="E9,F63,F7,F82,B012,B023"
HUB_UNUSED_SELECT="F401,F841,RUF059"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
_RUFF_OUT="$(mktemp)"
trap 'rm -f "${_RUFF_OUT}"; rm -rf "${_EMB_DIR:-}"' EXIT

# Plain python3 is the Store stub on Git Bash, silently no-opping the helpers. docs/shared-script-libraries.md#python-interpreter-probe-01-corepython-probesh
# shellcheck source=01-core/python-probe.sh
. "${_core}/python-probe.sh"
preflight_python_require lint-python.sh || exit 1
_LINT_PY="${PREFLIGHT_PYTHON}"

# shellcheck source=01-core/lint-scope-init.sh
. "${_core}/lint-scope-init.sh" || exit 1

_EMB_SH=()
if [ "$#" -gt 0 ]; then
  PY_FILES=()
  for f in "$@"; do
    case "${f}" in
      *.py) PY_FILES+=("${f}") ;;
      *.sh) _EMB_SH+=("${f}") ;;
      *) err "Expected a .py or .sh file, got ${f}" ;;
    esac
  done
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
# Heredoc Python, hub's or consumer's, is invisible to ruff otherwise. docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs
if [ "$#" -eq 0 ]; then
  if [ "${LINT_ROOT_GIVEN}" -eq 1 ]; then
    while IFS= read -r -d '' f; do _EMB_SH+=("${SCAN_ROOT}/${f}"); done \
      < <(lint_root_tracked "${SCAN_ROOT}" '*.sh')
  else
    while IFS= read -r f; do _EMB_SH+=("${f}"); done \
      < <(find linux/scripts -name '*.sh' -type f; find linux/host-config/git-hooks -type f)
  fi
fi
[ "${#PY_FILES[@]}" -gt 0 ] || [ "${#_EMB_SH[@]}" -gt 0 ] || err "No Python files found to lint under ${SCAN_ROOT}."
_lint_python_extract_batch() {
  [ "$#" -gt 0 ] || return 0
  # shellcheck disable=SC2086  # a multi-word PREFLIGHT_PYTHON is a command line
  ${_LINT_PY} linux/scripts/extract_embedded_python.py "${_EMB_DIR}" "$@" >> "${_EMB_MAP}"
}
if [ "${#_EMB_SH[@]}" -gt 0 ]; then
  _EMB_DIR="$(mktemp -d)" || err "Could not create embedded Python workspace"
  _EMB_MAP="${_EMB_DIR}/.sources"
  : > "${_EMB_MAP}" || err "Could not create embedded Python source map"
  _EMB_BATCH=()
  # Git Bash passes a Windows child one command line, so a whole-tree argv can exceed its limit.
  for f in "${_EMB_SH[@]}"; do
    _EMB_BATCH+=("${f}")
    if [ "${#_EMB_BATCH[@]}" -ge 32 ]; then
      _lint_python_extract_batch "${_EMB_BATCH[@]}" || err "Embedded Python extraction failed; refusing a partial lint result"
      _EMB_BATCH=()
    fi
  done
  _lint_python_extract_batch "${_EMB_BATCH[@]}" || err "Embedded Python extraction failed; refusing a partial lint result"
  while IFS= read -r f; do PY_FILES+=("${f}"); done \
    < <(find "${_EMB_DIR}" -name '*.py' -type f | sort)
fi
[ "${#PY_FILES[@]}" -gt 0 ] || { echo "No Python source or embedded blocks in the selected scripts"; exit 0; }

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

_lint_python_check() {
  local selector="$1" failed="$2" clean="$3"
  if ! "${RUFF[@]}" check --quiet --select "${selector}" "${PY_FILES[@]}" > "${_RUFF_OUT}" 2>&1; then
    _name_sources "${_RUFF_OUT}"
    echo ""
    err "${failed} (${selector})"
  fi
  echo "${clean} (${selector}): clean"
}

_lint_python_check "${GATE_SELECT}" "python gate pass failed" "gate pass"

# Consumer roots keep the older tier until their unused bindings are reviewed.
if [ "${LINT_ROOT_GIVEN}" -eq 0 ] && [ "$#" -eq 0 ]; then
  _lint_python_check "${HUB_UNUSED_SELECT}" "hub unused-binding gate failed" "hub unused-binding gate"
fi

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
