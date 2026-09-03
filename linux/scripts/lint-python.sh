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
# hard dependency of this repo; uvx caches the pinned wheel). PIN lives here
# for now — MOVE to versions.env as RUFF_VERSION on the next pin-bump window
# (Batch 3 rider; versions.env edits invalidate the media chain, so the pin
# must not land there out-of-band).
#
# Usage: linux/scripts/lint-python.sh [file.py ...]   (no args = full set)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# C4 (2026-08-26): read the pin from versions.env instead of duplicating it.
# The literal here silently drifted from RUFF_VERSION the moment that key was
# bumped; sourcing it is the one-line fix the backlog asked for.
_venv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/01-core/versions.env"
# shellcheck disable=SC1090
[ -f "${_venv}" ] && . "${_venv}"
RUFF_PIN="${RUFF_VERSION:-0.16.4}"
GATE_SELECT="E9,F63,F7,F82"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
# are assembled into one program later. docs/code-quality-tooling.md
if [ "$#" -eq 0 ]; then
  _EMB_DIR="$(mktemp -d)"
  trap 'rm -rf "${_EMB_DIR}"' EXIT
  if python3 linux/scripts/extract_embedded_python.py "${_EMB_DIR}" \
       $(find linux/scripts -name '*.sh' -type f) >/dev/null 2>&1; then
    while IFS= read -r f; do PY_FILES+=("${f}"); done \
      < <(find "${_EMB_DIR}" -name '*.py' -type f | sort)
  fi
fi

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
if ! "${RUFF[@]}" check --quiet --select "${GATE_SELECT}" "${PY_FILES[@]}"; then
  echo ""
  err "python gate pass failed (${GATE_SELECT}: syntax errors / undefined names / invalid asserts)"
fi
echo "gate pass (${GATE_SELECT}): clean"

# Advisory pass — full default ruleset, informational only.
echo ""
echo "-- advisory pass (full default ruleset; does not fail the gate) --"
if "${RUFF[@]}" check "${PY_FILES[@]}"; then
  echo "advisory pass: clean"
else
  echo ""
  echo "ADVISORY: findings above are informational (adoption ramp — tighten by"
  echo "promoting codes into GATE_SELECT once addressed; do not churn files"
  echo "just to satisfy style rules)."
fi
exit 0
