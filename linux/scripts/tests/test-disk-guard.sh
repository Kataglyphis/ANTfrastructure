#!/usr/bin/env bash
# Tests for 01-core/disk-guard.sh — the LRU victim picker and remaining-stage
# slug protection used by build-cross-chain.sh's between-stage disk guard.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/disk-guard.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# ---- _disk_guard_free_gb ----
# The preflight exists to stop a multi-hour ENOSPC death, so it must measure the
# cache dir's OWN filesystem and must never itself abort the orchestrator.
t_case "free_gb reports a number for an existing path"
free_root="$(_disk_guard_free_gb /)"
case "${free_root}" in
  ''|*[!0-9]*) t_assert_eq "<digits>" "${free_root}" "expected a numeric GB value for /" ;;
  *) t_assert_eq "0" "0" ;;
esac

t_case "free_gb walks up to the deepest existing ancestor"
# `df` fails outright on a not-yet-created dir — the first-run case. Walking up
# measures the filesystem the path will land on once mkdir'd.
t_assert_eq "${free_root}" "$(_disk_guard_free_gb /definitely/not/here/at/all)"

t_case "free_gb never aborts a caller running under set -euo pipefail"
# Regression: an unguarded df/du pipeline here propagated through pipefail and
# killed build-cross-chain.sh with a bare exit 1 and no diagnostic.
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  v="$(_disk_guard_free_gb /definitely/not/here)"
  w="$(_disk_guard_free_gb "")"
  exit 0'

t_case "pick_victim returns oldest-mtime unprotected slug"
mkdir -p "${workdir}/bc/slug-old" "${workdir}/bc/slug-mid" "${workdir}/bc/slug-new"
touch -d '3 days ago' "${workdir}/bc/slug-old" 2>/dev/null || touch -t 202601010000 "${workdir}/bc/slug-old"
touch -d '2 days ago' "${workdir}/bc/slug-mid" 2>/dev/null || touch -t 202601020000 "${workdir}/bc/slug-mid"
t_assert_eq "slug-old" "$(_disk_guard_pick_victim "${workdir}/bc" "")"

t_case "protected slugs are skipped"
t_assert_eq "slug-mid" "$(_disk_guard_pick_victim "${workdir}/bc" "slug-old")"
t_assert_eq "slug-new" "$(_disk_guard_pick_victim "${workdir}/bc" "slug-old,slug-mid")"

t_case "all-protected or missing dir yields empty (nothing prunable)"
t_assert_eq "" "$(_disk_guard_pick_victim "${workdir}/bc" "slug-old,slug-mid,slug-new")"
t_assert_eq "" "$(_disk_guard_pick_victim "${workdir}/does-not-exist" "")"

# ---- _disk_guard_protected_slugs with a stubbed stage graph ----
CROSS_STAGE_ORDER=(base compiler sdk media)
TARGET_ARCHES="amd64,arm64"
stage_enabled() { [ "$1" != "media" ]; }             # media disabled this run
cross_stage_is_per_arch() { [ "$1" = "sdk" ] || [ "$1" = "media" ]; }
cross_stage_tag() {
  if [ "$#" -ge 2 ]; then printf 'repo/img:cross-%s-%s' "$1" "$2"
  else printf 'repo/img:%s' "$1"; fi
}
arch_list_to_words() { printf '%s' "${1//,/ }"; }

t_case "protects only enabled stages after the completed one"
t_assert_eq "repo_img_compiler,repo_img_cross-sdk-amd64,repo_img_cross-sdk-arm64" \
            "$(_disk_guard_protected_slugs base)"
t_assert_eq "repo_img_cross-sdk-amd64,repo_img_cross-sdk-arm64" \
            "$(_disk_guard_protected_slugs compiler)"
t_assert_eq "" "$(_disk_guard_protected_slugs sdk)"

t_case "empty completed stage protects all enabled stages"
t_assert_eq "repo_img_base,repo_img_compiler,repo_img_cross-sdk-amd64,repo_img_cross-sdk-arm64" \
            "$(_disk_guard_protected_slugs '')"

t_summary
