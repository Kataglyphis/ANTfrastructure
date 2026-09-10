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
# RUFF_VERSION in 01-core/versions.env and NOWHERE ELSE — this file carries no
# fallback literal, and refuses to run rather than invent one (see below).
#
# Usage: linux/scripts/lint-python.sh [--root <dir>] [file.py ...]
#        (no file arguments = the full set under the root)
#
# --root is the same contract lint-workflows.sh and lint-shell.sh document, for
# the same reason: a submodule checkout puts this script INSIDE the consumer,
# where the default root resolves to ContainerHub and the gate grades the wrong
# tree while reporting green over one nobody looked at. It is what lets a
# consumer's Python be reached at all — OrchestrANT's 65 files were outside
# every lint gate in the fleet until this argument existed. The ruff pin,
# versions.env and the extractor always come from THIS repo regardless.
#
# Under a root the file set is `git ls-files`, not a find: a vendored submodule
# (this very repo, at third_party/ContainerHub) is a GITLINK there, so the
# consumer's scope cannot quietly swallow the hub's own Python, and untracked
# build output cannot get in either. The root must therefore be a git checkout,
# which is checked rather than assumed.
#
# An empty file list is already fatal below and stays fatal under a root: a gate
# handed a tree and reporting green over nothing is worse than no gate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

# C4 (2026-08-26): read the pin from versions.env instead of duplicating it.
# Through the safe loader, never `source`: versions.env is inert data whose
# values may contain shell metacharacters, and sourcing it ran three of
# CUDA_ARCHITECTURES' arch numbers as commands on every hook run.
# docs/cross-build-verification.md#per-arch-version-truth
#
# RUFF_VERSION below is `:?`, never `:-` (2026-09-09): a `:-` fallback IS a
# second literal, reconciled only by an advisory scan that exits 0. Same
# argument as scan-image-sbom.sh's SYFT_VERSION.
# docs/code-quality-tooling.md#the-two-that-stay-frozen-with-better-reasons
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

# --root is parsed and resolved by the contract's one owner; what comes back is
# the tree to grade. The remaining arguments go back into "$@", so the staged /
# pre-commit call shape below is untouched.
# shellcheck source=01-core/lint-root.sh
. "${_core}/lint-root.sh"
lint_root_begin "${REPO_ROOT}" "$@" || exit 1
SCAN_ROOT="${LINT_ROOT_PATH}"
set -- ${LINT_ROOT_REST[@]+"${LINT_ROOT_REST[@]}"}

# ---------------------------------------------------------------------------
# Target set — first-party Python only (vendored/venv/checkout trees excluded)
# ---------------------------------------------------------------------------
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

# Python living in shell heredocs is invisible to ruff otherwise (775 lines as of
# 2026-09-01). Only directly-executed blocks are self-contained; `cat`ed fragments
# are assembled into one program later. The git hooks are in scope too: a hook
# cannot carry a .sh suffix. docs/code-quality-tooling.md#python-that-lives-in-shell-heredocs
#
# Under a root the two hub directories name nothing, so the shell handed to the
# extractor is the CONSUMER's tracked shell. Skipping this step there would have
# been the quiet half-gate this whole file argues against: heredoc Python is
# still Python, and a consumer's is no more visible to ruff than the hub's.
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
  if python3 linux/scripts/extract_embedded_python.py "${_EMB_DIR}" \
       ${_EMB_SH[@]+"${_EMB_SH[@]}"} > "${_EMB_MAP}" 2>/dev/null; then
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
