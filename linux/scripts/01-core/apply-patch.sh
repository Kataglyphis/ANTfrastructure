#!/usr/bin/env bash
# apply-patch.sh — Idempotently apply a patch to a source directory.
#
# Usage: apply-patch.sh <patch_file> <source_dir> [description]
#
# Behaviour:
#   1. If the patch is already applied (reverse-apply check passes), skip.
#   2. If the patch applies cleanly (forward check passes), apply it.
#   3. If neither works, print a loud error and return 1.
#
# Works with both git working trees (git apply) and extracted tarballs
# (patch -p1). Git is preferred when available; patch(1) is the fallback.
#
# Patches are plain `git diff` / `diff -u` output — reviewable, version-pinned,
# and committed to the repo under linux/scripts/patches/.
set -euo pipefail

patch_file="${1:?patch file is required}"
source_dir="${2:?source directory is required}"
description="${3:-$(basename "${patch_file}" .patch)}"

if [ ! -f "${patch_file}" ]; then
  echo "ERROR: patch file not found: ${patch_file}" >&2
  return 1 2>/dev/null || exit 1
fi

# Detect whether source_dir is inside a git working tree
_is_git_repo() {
  [ -d "${source_dir}/.git" ] || git -C "${source_dir}" rev-parse --git-dir >/dev/null 2>&1
}

if _is_git_repo; then
  # Git-based apply (preferred)
  # 1. Already applied?
  if git -C "${source_dir}" apply --reverse --check "${patch_file}" 2>/dev/null; then
    echo "  SKIP: ${description} (already applied)"
    return 0 2>/dev/null || exit 0
  fi
  # 2. Apply forward
  if git -C "${source_dir}" apply --check "${patch_file}" 2>/dev/null; then
    git -C "${source_dir}" apply "${patch_file}"
    echo "  APPLIED: ${description}"
    return 0 2>/dev/null || exit 0
  fi
else
  # Non-git (extracted tarball) — use patch(1)
  # 1. Already applied? (reverse dry-run)
  if patch -p1 --dry-run --reverse < "${patch_file}" -d "${source_dir}" 2>/dev/null; then
    echo "  SKIP: ${description} (already applied)"
    return 0 2>/dev/null || exit 0
  fi
  # 2. Apply forward
  if patch -p1 --dry-run < "${patch_file}" -d "${source_dir}" 2>/dev/null; then
    patch -p1 < "${patch_file}" -d "${source_dir}"
    echo "  APPLIED: ${description}"
    return 0 2>/dev/null || exit 0
  fi
fi

# 3. Patch does not apply cleanly
echo "ERROR: ${description} — patch does not apply cleanly to ${source_dir}" >&2
echo "       The upstream source may have changed. Regenerate the patch with:" >&2
echo "       bash linux/scripts/patches/generate-patches.sh --component <name>" >&2
echo "--- patch file: ${patch_file} ---" >&2
head -40 "${patch_file}" >&2
echo "..." >&2
return 1 2>/dev/null || exit 1
