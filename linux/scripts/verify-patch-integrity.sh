#!/usr/bin/env bash
# verify-patch-integrity.sh — static integrity gate for linux/scripts/patches/.
#
# A malformed or orphaned patch is a landmine: it only detonates deep inside a
# multi-hour cross build when apply-patch.sh finally reaches it. This catches
# both classes in seconds, before the rebuild:
#
#   1. WELL-FORMED   — every *.patch parses as a unified diff (---/+++/@@ hunks),
#                      so `git apply`/`patch -p1` will not choke on a truncated or
#                      hand-mangled file.
#   2. REFERENCED    — every *.patch is named by at least one build script, so a
#                      renamed/removed apply site cannot leave a patch silently
#                      dead (its fix quietly stops being applied).
#
# Non-fatal advisory: patches whose apply site does NOT route through the
# idempotent apply-patch.sh helper (raw `git apply`/`patch`) are reported as
# INFO, not failures — some sites legitimately pre-date the helper.
#
# Usage: linux/scripts/verify-patch-integrity.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_DIR="${REPO_ROOT}/linux/scripts/patches"
SCRIPTS_DIR="${REPO_ROOT}/linux/scripts"

pass_n=0
fail_n=0
pass() { printf '  PASS %s\n' "$1"; pass_n=$((pass_n + 1)); }
fail() { printf '  FAIL %s\n' "$1" >&2; fail_n=$((fail_n + 1)); }

echo "=== Patch integrity (linux/scripts/patches) ==="

if [ ! -d "${PATCH_DIR}" ]; then
  echo "  no patches directory at ${PATCH_DIR}; nothing to check."
  exit 0
fi

mapfile -t _patches < <(find "${PATCH_DIR}" -name '*.patch' | sort)
if [ "${#_patches[@]}" -eq 0 ]; then
  echo "  no *.patch files found; nothing to check."
  exit 0
fi

echo "  found ${#_patches[@]} patch file(s)"
echo ""

for _p in "${_patches[@]}"; do
  _rel="${_p#"${REPO_ROOT}/"}"
  _base="$(basename "${_p}")"

  # 1. Well-formed unified diff: needs at least one ---, +++ and @@ hunk header.
  if grep -qE '^--- ' "${_p}" && grep -qE '^\+\+\+ ' "${_p}" && grep -qE '^@@ ' "${_p}"; then
    pass "well-formed diff: ${_rel}"
  else
    fail "not a valid unified diff (missing ---/+++/@@): ${_rel}"
  fi

  # 2. Referenced by some build script (by basename), excluding the patch itself.
  if grep -rlF "${_base}" "${SCRIPTS_DIR}" --include='*.sh' | grep -qv "^${_p}$"; then
    # 2b. Advisory: does any referencing site route through apply-patch.sh?
    if grep -rlF "${_base}" "${SCRIPTS_DIR}" --include='*.sh' \
         | xargs grep -lE 'apply-patch\.sh|android_apply_patch' 2>/dev/null | grep -q .; then
      pass "referenced via apply-patch helper: ${_base}"
    else
      pass "referenced: ${_base}"
      echo "    INFO: applied without the idempotent apply-patch.sh helper (raw git apply/patch)"
    fi
  else
    fail "orphaned patch — no build script references ${_base}"
  fi
done

echo ""
echo "=== Results: ${pass_n} passed, ${fail_n} failed ==="
[ "${fail_n}" -eq 0 ]
