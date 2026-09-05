#!/usr/bin/env bash
# lint-python.sh — static Python gate: ruff. No imports are executed; safe for
# CI and hooks. Closes the lint asymmetry (backlog 2026-08-10 C4): shell,
# Dockerfiles, workflows and PowerShell all have gates — ~3,300 first-party
# Python lines had none.
#
# TWO-PASS DESIGN (the PSSA advisory-ramp precedent, windows-scripts.yml):
#   gate pass  — `ruff check --select E9,F63,F7,F82` (syntax errors, invalid
#                comparisons/asserts, undefined names): near-zero false
#                positives, HARD-fails. An undefined name in bump_versions.py
#                is a real crash waiting for its code path.
#   advisory   — full default ruleset, findings printed, never fails. Tighten
#                by moving codes into GATE_SELECT once the tree is clean-ish.
#
# ruff bootstrap: PATH copy preferred; else `uvx ruff@PIN` (uv is already a
# hard dependency of this repo; uvx caches the pinned wheel). The pin is
# RUFF_VERSION in 01-core/versions.env, sourced below.
#
# Usage: linux/scripts/lint-python.sh [file.py ...]   (no args = full set)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# C4 (2026-08-26): read the pin from versions.env instead of duplicating it.
# Through the safe loader, never `source`: versions.env is inert data whose
# values may contain shell metacharacters, and sourcing it ran three of
# CUDA_ARCHITECTURES' arch numbers as commands on every hook run.
# docs/cross-build-verification.md#per-arch-version-truth
_core="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core"
if [ -f "${_core}/versions.env" ] && [ -f "${_core}/load-versions-env.sh" ]; then
  # shellcheck source=01-core/load-versions-env.sh
  . "${_core}/load-versions-env.sh" && load_versions_env "${_core}/versions.env"
fi
RUFF_PIN="${RUFF_VERSION:-0.16.4}"
GATE_SELECT="E9,F63,F7,F82"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
_RUFF_OUT="$(mktemp)"
trap 'rm -f "${_RUFF_OUT}"; rm -rf "${_EMB_DIR:-}"' EXIT

# ---------------------------------------------------------------------------
# Target set — first-party Python only (vendored/venv/checkout trees excluded)
# ---------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
  PY_FILES=("$@")
else
  PY_FILES=()
  while IFS= read -r f; do
    PY_FILES+=("${f}")
  done < <(find docs/scripts linux/scripts linux/llm-stack linux/webserver \
             -name '*.py' -type f \
             -not -path '*/node_modules/*' -not -path '*/__pycache__/*' \
             -not -path '*/.venv/*' 2>/dev/null | sort)
fi
[ "${#PY_FILES[@]}" -gt 0 ] || err "No Python files found to lint."

# Python living in shell heredocs is invisible to ruff otherwise (775 lines as of
# 2026-09-01). Only directly-executed blocks are self-contained; `cat`ed fragments
# are assembled into one program later. The git hooks are in scope too: a hook
# cannot carry a .sh suffix. docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs
if [ "$#" -eq 0 ]; then
  _EMB_DIR="$(mktemp -d)"
  _EMB_MAP="${_EMB_DIR}/.sources"
  if python3 linux/scripts/extract_embedded_python.py "${_EMB_DIR}" \
       $(find linux/scripts -name '*.sh' -type f; find linux/host-config/git-hooks -type f) > "${_EMB_MAP}" 2>/dev/null; then
    while IFS= read -r f; do PY_FILES+=("${f}"); done \
      < <(find "${_EMB_DIR}" -name '*.py' -type f | sort)
  fi
fi

# A finding in an extracted block is named `probe__2.py:1:` -- opener line in one
# number, body line in the other, added by hand by whoever reads it. The
# extractor's map turns the pair back into the shell file and its real line.
# docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs
_name_sources() {
  python3 - "${_EMB_MAP:-/dev/null}" "$1" <<'EMBPY'
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

# ---------------------------------------------------------------------------
# ruff bootstrap (PATH copy preferred; else pinned uvx)
# ---------------------------------------------------------------------------
RUFF=()
if command -v ruff >/dev/null 2>&1; then
  RUFF=(ruff)
elif command -v uvx >/dev/null 2>&1; then
  RUFF=(uvx "ruff@${RUFF_PIN}")
else
  err "neither ruff nor uvx found — install uv (repo standard) or ruff"
fi

echo "== python lint: ${#PY_FILES[@]} file(s), ruff via '${RUFF[*]}' =="

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
