#!/usr/bin/env bash
# Every linux/scripts/patches/*.patch is a well-formed diff named by a build script, caught here rather than hours into a build.
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

  # 2. Referenced by some build script, by basename.
  if grep -rlF "${_base}" "${SCRIPTS_DIR}" --include='*.sh' | grep -q .; then
    # 2b. Advisory only: some apply sites predate the idempotent apply-patch.sh helper.
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
