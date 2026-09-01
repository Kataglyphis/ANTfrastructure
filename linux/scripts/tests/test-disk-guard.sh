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

# ---- _disk_guard_trim_cache_export (D4: the preflight cache-export trim) ----
# kata-buildcache grew 62G -> 110G in ONE session and forced a controlled chain
# stop at 19G free. The trim must reclaim OLDEST-first, respect its budget
# instead of nuking the dir, say what it removed, and be a no-op when disk is
# ample. Free space is stubbed via a file: the real function is called inside
# $(...) subshells, so an in-memory sequence variable would never advance.
seqfile="${workdir}/free.seq"
_disk_guard_free_gb() {
  local n
  n="$(head -1 "${seqfile}" 2>/dev/null)"
  # Last line repeats forever; earlier ones are consumed one call at a time.
  if [ "$(wc -l < "${seqfile}" 2>/dev/null || echo 1)" -gt 1 ]; then
    sed -i '1d' "${seqfile}"
  fi
  printf '%s' "${n}"
}
_stub_free() { printf '%s\n' "$@" > "${seqfile}"; }

# Three ~2 MiB slug dirs, oldest first. touch AFTER writing: adding a file
# bumps the directory mtime and would flatten the ordering.
BC="${workdir}/trim"
_mk_bc() {
  local s
  rm -rf "${BC}"; mkdir -p "${BC}"
  for s in slug-a slug-b slug-c; do
    mkdir -p "${BC}/${s}"
    dd if=/dev/zero of="${BC}/${s}/blob" bs=1024 count=2048 status=none
  done
  touch -d '3 days ago' "${BC}/slug-a"
  touch -d '2 days ago' "${BC}/slug-b"
  touch -d '1 day ago'  "${BC}/slug-c"
}
_present() { [ -d "${BC}/$1" ] && printf 'yes' || printf 'no'; }

t_case "trim is a NO-OP when free space is ample"
_mk_bc; _stub_free 100
_disk_guard_trim_cache_export "${BC}" 40 "" "" 0 > "${workdir}/out.txt"
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "0" "${_DISK_GUARD_TRIM_FREED_BYTES}"
t_assert_eq "yes yes yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"
t_assert_eq "" "$(cat "${workdir}/out.txt")" "an ample-disk run must log nothing"
# Also with an explicit budget: without this the ample-disk guard is masked by
# the negative-budget fallback and could be deleted without a test going red.
_disk_guard_trim_cache_export "${BC}" 40 "" 1073741824 0 > "${workdir}/out.txt"
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "yes yes yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"

t_case "trim removes OLDEST-first and stops at the byte budget"
# Budget 3 MiB against 3x ~2 MiB slugs: exactly two removals, newest survives.
_mk_bc; _stub_free 10
_disk_guard_trim_cache_export "${BC}" 40 "" 3145728 0 > "${workdir}/out.txt"
t_assert_eq "2" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "no no yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"
t_assert_eq "slug-a slug-b" \
  "$(sed -n 's/.*removed \(slug-[abc]\) .*/\1/p' "${workdir}/out.txt" | tr '\n' ' ' | sed 's/ $//')" \
  "removal order must be oldest-first"

t_case "trim LOGS every removal and the total it freed"
t_assert_contains "$(cat "${workdir}/out.txt")" "removed slug-a"
t_assert_contains "$(cat "${workdir}/out.txt")" "removed 2 slug(s), freed"

t_case "trim stops as soon as free space reaches the target"
# Budget is 100 MiB (would take all three); the second df says 50G >= 40G.
_mk_bc; _stub_free 10 50
_disk_guard_trim_cache_export "${BC}" 40 "" 104857600 0 > "${workdir}/out.txt"
t_assert_eq "1" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "no yes yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"

t_case "trim never removes a protected slug"
_mk_bc; _stub_free 10
_disk_guard_trim_cache_export "${BC}" 40 "slug-a" 1073741824 0 > "${workdir}/out.txt"
t_assert_eq "2" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "yes no no" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"

t_case "trim is a no-op on a missing dir, a bad target or unknown free space"
_stub_free 10
_disk_guard_trim_cache_export "${workdir}/no-such-dir" 40 ""
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}"
_mk_bc
_disk_guard_trim_cache_export "${BC}" "lots" ""
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "yes yes yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"
_stub_free ""
_disk_guard_trim_cache_export "${BC}" 40 "" "" 0
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}"
t_assert_eq "yes yes yes" "$(_present slug-a) $(_present slug-b) $(_present slug-c)"

t_case "trim never aborts a caller running under set -euo pipefail"
# Real df here (no stub): an unreachable target drives the full loop.
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  d="$(mktemp -d)"; mkdir -p "${d}/s1" "${d}/s2"
  _disk_guard_trim_cache_export "${d}" 999999 "" "" 0
  rm -rf "${d}"
  exit 0'


# ---- keep-floor: the trim must never empty the cache-export dir --------------
# Without it the byte budget does NOT bound the loop: when the deficit exceeds
# the whole directory (the common case) it runs until pick_victim is dry.
t_case "trim keeps the newest N slugs even when the deficit is unbounded"
_kf="$(mktemp -d)"
for _i in 1 2 3 4 5 6; do
  mkdir -p "${_kf}/s${_i}"; : > "${_kf}/s${_i}/blob"
  touch -d "2026-08-0${_i}" "${_kf}/s${_i}"
done
_disk_guard_free_gb() { echo 1; }
_disk_guard_trim_cache_export "${_kf}" 999999 "" "" 3 >/dev/null 2>&1
t_assert_eq "3" "$(find "${_kf}" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "keep-floor must leave exactly 3"
t_assert_eq "s4 s5 s6" "$(find "${_kf}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')" "the NEWEST must survive"
rm -rf "${_kf}"

# ---------------------------------------------------------------------------
# B2: in-stage sampling. The runtime lane is ONE stage of three ~120G wrapper
# builds, so the between-stage guard cannot fire in it — `grep -c disk-guard`
# over the whole 483 MB log of the 2026-09-01 failure returns 0, including the
# 28 minutes the disk drained from 88G to 4G.
_wd="$(mktemp -d)"
_mkwd() {
  local s
  rm -rf "${_wd}/bc"; mkdir -p "${_wd}/bc"
  for s in w-a w-b w-c w-d; do
    mkdir -p "${_wd}/bc/${s}"
    dd if=/dev/zero of="${_wd}/bc/${s}/blob" bs=1024 count=1024 status=none
  done
  touch -d '4 days ago' "${_wd}/bc/w-a"; touch -d '3 days ago' "${_wd}/bc/w-b"
  touch -d '2 days ago' "${_wd}/bc/w-c"; touch -d '1 day ago'  "${_wd}/bc/w-d"
}

t_case "watch_once SAMPLES on every call — the silent drain is the whole bug"
_mkwd; _disk_guard_free_gb() { echo 500; }
_DISK_GUARD_TRIM_REMOVED=99
_disk_guard_watch_once "${_wd}/bc" 40 "" 3 > "${_wd}/o.txt" 2>&1
t_assert_contains "$(cat "${_wd}/o.txt")" "[disk-watch] 500G free" "an in-stage sample must always be logged"
t_assert_eq "99" "${_DISK_GUARD_TRIM_REMOVED}" "ample disk must not even enter the trim"

t_case "watch_once reclaims and RECORDS the reclaim when below threshold"
_mkwd; _disk_guard_free_gb() { echo 10; }
_disk_guard_watch_once "${_wd}/bc" 40 "" 3 > "${_wd}/o.txt" 2>&1
t_assert_eq "1" "${_DISK_GUARD_TRIM_REMOVED}" "keep-floor 3 of 4 slugs leaves exactly one removal"
t_assert_eq "no" "$( [ -d "${_wd}/bc/w-a" ] && echo yes || echo no )" "oldest slug must go first"
t_assert_contains "$(cat "${_wd}/o.txt")" "[disk-reclaim] in-stage: removed 1 cache-export slug(s), freed" \
  "every reclaim the chain performs must leave ONE greppable record"

t_case "a reclaim that frees nothing still WARNS — the case an operator must see"
_mkwd; rm -rf "${_wd}/bc"; mkdir -p "${_wd}/bc"     # nothing prunable at all
_disk_guard_free_gb() { echo 4; }
_disk_guard_watch_once "${_wd}/bc" 40 "" 3 > "${_wd}/o.txt" 2>&1
t_assert_contains "$(cat "${_wd}/o.txt")" "[disk-reclaim] in-stage: NOTHING was reclaimable" \
  "a silent no-op reclaim is what made the 2026-09-01 drain unreconstructible"

t_case "watch_once never aborts the stage it samples (set -euo pipefail)"
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  _disk_guard_watch_once "/definitely/not/here" 40 "" 3 >/dev/null 2>&1
  _disk_guard_watch_once "" "" "" "" >/dev/null 2>&1
  exit 0'

t_case "watch_loop samples repeatedly, not once"
_mkwd; _disk_guard_free_gb() { echo 500; }
_DISK_GUARD_WATCH_MAX_ITERS=3 _disk_guard_watch_loop "${_wd}/bc" 40 1 "" 3 > "${_wd}/o.txt" 2>&1
t_assert_eq "3" "$(grep -c -e '\[disk-watch\] 500G free' "${_wd}/o.txt")" "the loop must keep sampling for the whole stage"
rm -rf "${_wd}"

# ---------------------------------------------------------------------------
# Runtime-lane sizing. The start-of-run preflight sized ~60G/arch and never
# accounted for the lane; ~120G per wrapper build was measured in the resource
# CSV. Arches build SEQUENTIALLY unless --parallel-archs, so the need scales
# with concurrency — multiplying by arch count would refuse every run on a host
# that can in fact complete one.
t_case "runtime-lane need is per-concurrent-build, not per-arch"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb 120 3 0)"
t_assert_eq "360" "$(_disk_guard_runtime_lane_need_gb 120 3 1)"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb 120 1 1)"

t_case "runtime-lane need falls back to sane numbers on junk input"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb "" "" "")"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb "lots" "many" "0")"
t_assert_eq "0"   "$(_disk_guard_runtime_lane_need_gb 0 3 1)" "0 must disable, not default"

t_summary
