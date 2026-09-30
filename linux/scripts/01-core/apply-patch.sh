#!/usr/bin/env bash
# apply-patch.sh <patch_file> <source_dir> [description]: idempotent; skips an applied patch, fails loudly on a stale one.
set -euo pipefail

patch_file="${1:?patch file is required}"
source_dir="${2:?source directory is required}"
description="${3:-$(basename "${patch_file}" .patch)}"

if [ ! -f "${patch_file}" ]; then
  echo "ERROR: patch file not found: ${patch_file}" >&2
  return 1 2>/dev/null || exit 1
fi

_is_git_repo() {
  [ -d "${source_dir}/.git" ] || git -C "${source_dir}" rev-parse --git-dir >/dev/null 2>&1
}

if _is_git_repo; then
  # A reverse-apply that checks clean means already applied.
  if git -C "${source_dir}" apply --reverse --check "${patch_file}" 2>/dev/null; then
    echo "  SKIP: ${description} (already applied)"
    return 0 2>/dev/null || exit 0
  fi
  if git -C "${source_dir}" apply --check "${patch_file}" 2>/dev/null; then
    git -C "${source_dir}" apply "${patch_file}"
    echo "  APPLIED: ${description}"
    return 0 2>/dev/null || exit 0
  fi
else
  # An extracted tarball: patch(1), same reverse-then-forward order.
  if patch -p1 --dry-run --reverse < "${patch_file}" -d "${source_dir}" 2>/dev/null; then
    echo "  SKIP: ${description} (already applied)"
    return 0 2>/dev/null || exit 0
  fi
  if patch -p1 --dry-run < "${patch_file}" -d "${source_dir}" 2>/dev/null; then
    patch -p1 < "${patch_file}" -d "${source_dir}"
    echo "  APPLIED: ${description}"
    return 0 2>/dev/null || exit 0
  fi
fi

echo "ERROR: ${description} — patch does not apply cleanly to ${source_dir}" >&2
echo "       The upstream source may have changed. Regenerate the patch with:" >&2
echo "       bash linux/scripts/patches/generate-patches.sh --component <name>" >&2
echo "--- patch file: ${patch_file} ---" >&2
head -40 "${patch_file}" >&2
echo "..." >&2
return 1 2>/dev/null || exit 1
