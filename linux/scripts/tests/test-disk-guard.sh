#!/usr/bin/env bash
# 01-core/disk-guard.sh: the LRU victim picker, slug protection and the reclaim levers.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/../01-core/disk-guard.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Off unless stubbed: a real buildctl would prune this host's store; see docs/build-cache-tiers.md#321-the-buildkit-store-fallback-disk1
export CROSS_BUILDKIT_PRUNE=0

# _disk_guard_free_gb measures the cache dir's own filesystem and must never abort the orchestrator.
t_case "free_gb reports a number for an existing path"
free_root="$(_disk_guard_free_gb /)"
case "${free_root}" in
  ''|*[!0-9]*) t_assert_eq "<digits>" "${free_root}" "expected a numeric GB value for /" ;;
  *) t_assert_eq "0" "0" ;;
esac

t_case "free_gb walks up to the deepest existing ancestor"
# `df` fails on a not-yet-created dir, which is the first-run case.
t_assert_eq "${free_root}" "$(_disk_guard_free_gb /definitely/not/here/at/all)"

t_case "free_gb never aborts a caller running under set -euo pipefail"
# An unguarded df/du pipeline would kill the orchestrator through pipefail with no diagnostic.
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

# Trim: free space is stubbed via a file, because $(...) subshells never advance an in-memory sequence.
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

# touch after writing: adding a file bumps the directory mtime and would flatten the ordering.
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
# With an explicit budget too, or the negative-budget fallback masks the ample-disk guard.
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


# Keep-floor: a deficit larger than the whole dir would otherwise run the trim until it is empty.
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

# In-stage sampling: the runtime lane is one long stage, where the between-stage guard never fires.
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

# Arches build sequentially unless --parallel-archs, so the lane's need scales with concurrency, not arch count.
t_case "runtime-lane need is per-concurrent-build, not per-arch"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb 120 3 0)"
t_assert_eq "360" "$(_disk_guard_runtime_lane_need_gb 120 3 1)"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb 120 1 1)"

t_case "runtime-lane need falls back to sane numbers on junk input"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb "" "" "")"
t_assert_eq "120" "$(_disk_guard_runtime_lane_need_gb "lots" "many" "0")"
t_assert_eq "0"   "$(_disk_guard_runtime_lane_need_gb 0 3 1)" "0 must disable, not default"

t_case "the anti-spin append must use the separator pick_victim matches on"
# pick_victim matches on commas, so a space-joined protect list re-picks the same slug forever.
t_assert_eq "slug-old" "$(_disk_guard_pick_victim "${workdir}/bc" "slug-old slug-mid")" \
  "a space-joined list protects NOTHING -- the oldest is picked again, forever"
t_assert_eq "slug-new" "$(_disk_guard_pick_victim "${workdir}/bc" "slug-old,slug-mid")" \
  "the comma form is what actually protects"
# Structural half: the behavioural test re-creates the string, so it cannot catch the caller switching back.
_chain="${TESTS_DIR}/../build-cross-chain.sh"
t_assert_eq "0" "$(grep -c -e '_prot_ref="${_prot_ref} ${victim}"' "${_chain}" || true)" \
  "build-cross-chain.sh must not append a protected slug with a space"
# Both eviction loops share _chain_evict_slugs; its nameref is what appends into the caller's list.
t_assert_eq "1" "$(grep -c -e '_prot_ref="${_prot_ref},${victim}"' "${_chain}" || true)" \
  "the one anti-spin site must append with a comma"
t_assert_eq "1" "$(grep -c -e 'local -n _prot_ref=' "${_chain}" || true)" \
  "a by-value copy would protect nothing outside the loop, which is the same spin"

# DISK1: the filtered buildkit-store fallback, with buildctl and df stubbed so no test prunes the real store.
_bk="$(mktemp -d)"
mkdir -p "${_bk}/bin" "${_bk}/bc" "${_bk}/empty"
BUILDCTL_LOG="${_bk}/buildctl.log"
BUILDCTL_PRUNED="${_bk}/pruned"
export BUILDCTL_LOG BUILDCTL_PRUNED
cat > "${_bk}/bin/buildctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BUILDCTL_LOG}"
[ "${BUILDCTL_UNREACHABLE:-0}" = "1" ] && exit 1
case " $* " in *" --format "*) printf '%s\n' "${BUILDCTL_DU_JSON:-[]}"; exit 0 ;; esac
if [ "$1" = "du" ] && [ "$2" = "--filter" ]; then
  n=97
  [ -f "${BUILDCTL_PRUNED}" ] && n="${BUILDCTL_MOUNTS_AFTER:-${n}}"
  i=0; while [ "${i}" -lt "${n}" ]; do printf 'mount-%s\n' "${i}"; i=$(( i + 1 )); done
fi
[ "$1" = "prune" ] && : > "${BUILDCTL_PRUNED}"
exit 0
STUB
chmod +x "${_bk}/bin/buildctl"
PATH="${_bk}/bin:${PATH}"
export CROSS_BUILDKIT_PRUNE=1
# Free space before and after the stubbed prune.
_disk_guard_free_gb() {
  if [ -f "${BUILDCTL_PRUNED}" ]; then echo "${BK_FREE_AFTER:-227}"; else echo 4; fi
}
_bk_reset() {
  rm -f "${BUILDCTL_PRUNED}"; : > "${BUILDCTL_LOG}"
  _DISK_GUARD_BUILDKIT_PRUNES=0
  _DISK_GUARD_BUILDKIT_FREED_GB=0
  _DISK_GUARD_TRIM_REMOVED=0
  _DISK_GUARD_TRIM_FREED_BYTES=0
  unset BUILDCTL_UNREACHABLE BUILDCTL_MOUNTS_AFTER
}
_bk_prunes() { grep -c -e '^prune ' "${BUILDCTL_LOG}" 2>/dev/null || true; }

t_case "the trim runs FIRST — a fallback that fires while disk is ample is a bug"
_bk_reset
_disk_guard_free_gb() { echo 100; }
_disk_guard_buildkit_fallback "${_bk}/bc" 40 > "${_bk}/o.txt" 2>&1
t_assert_eq "0" "$(_bk_prunes)" "40G target with 100G free must never reach buildctl"
t_assert_eq "" "$(cat "${_bk}/o.txt")" "an ample-disk fallback must log nothing"
_disk_guard_free_gb() {
  if [ -f "${BUILDCTL_PRUNED}" ]; then echo "${BK_FREE_AFTER:-227}"; else echo 4; fi
}

t_case "watch_once falls back to buildctl only after the trim comes up short"
# The cache-export dir has nothing prunable (keep_n 3), so only the store can help.
_bk_reset
_disk_guard_watch_once "${_bk}/bc" 40 "" 3 > "${_bk}/o.txt" 2>&1
t_assert_eq "0" "${_DISK_GUARD_TRIM_REMOVED}" "there is nothing for the trim to remove"
t_assert_eq "1" "$(_bk_prunes)" "the guard must reach the buildkit store instead of giving up"

t_case "the prune is FILTERED and carries a keep-storage value"
t_assert_contains "$(cat "${BUILDCTL_LOG}")" "prune --filter type==regular --keep-storage 120000" \
  "an unfiltered prune eats the exec.cachemount records — 1.5-2h of cold LLVM"

# Banned are the forms that delete exec.cachemount records; `nerdctl image prune` and `rmi` spare them.
t_case "the destructive command is never reachable from the guard"
t_assert_eq "0" "$(grep -c -e 'nerdctl' "${BUILDCTL_LOG}" || true)" \
  "the BUILDKIT fallback must reach buildctl and nothing else"
_dg="${TESTS_DIR}/../01-core/disk-guard.sh"
t_assert_eq "0" "$(grep -c -e 'builder prune' "${_dg}" || true)" \
  "'nerdctl builder prune -f' deletes the cache mounts; only the filtered buildctl form is allowed"
t_assert_eq "0" "$(grep -c -e 'system prune' "${_dg}" || true)" \
  "'nerdctl system prune' takes T0+T1 with it -- 35 cache-mount records went to 1 on 2026-08-21"
t_assert_eq "0" "$(grep -c -e 'image prune -a' "${_dg}" || true)" \
  "-a removes every unreferenced image, including the parents this run pinned"

t_case "a human reading the log sees HOW MUCH was reclaimed, and from where"
t_assert_contains "$(cat "${_bk}/o.txt")" "[disk-buildkit] 4G free < 40G after the cache-export trim"
t_assert_contains "$(cat "${_bk}/o.txt")" "reclaimed 223G of layer cache" \
  "a reclaim nobody can quantify from the log is what made 2026-09-03 unreconstructible"
t_assert_contains "$(cat "${_bk}/o.txt")" "all 97 cache-mount record(s) survived"

t_case "the reclaim record CREDITS the buildkit prune instead of crying defeat"
t_assert_contains "$(cat "${_bk}/o.txt")" "+ 223G of buildkit layer cache"
t_assert_eq "0" "$(grep -c -e 'NOTHING was reclaimable' "${_bk}/o.txt" || true)" \
  "223G were reclaimed; the give-up warning would now be a lie"

t_case "the fallback runs ONCE, not once per sample"
# After the first prune the store is at keep-storage; a repeat walk only costs I/O.
BK_FREE_AFTER=10 _disk_guard_watch_once "${_bk}/bc" 40 "" 3 > "${_bk}/o2.txt" 2>&1
t_assert_eq "1" "$(_bk_prunes)" "a second sample must not re-prune"
t_assert_contains "$(cat "${_bk}/o2.txt")" "already pruned once here"

t_case "keep-storage never drops below the 100G recompile-churn floor"
_bk_reset
CROSS_BUILDKIT_KEEP_GB=40 _disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
t_assert_contains "$(cat "${BUILDCTL_LOG}")" "--keep-storage 100000" \
  "keeping under 100G mid-run costs recompile churn (rebuild-disk-management)"
_bk_reset
CROSS_BUILDKIT_KEEP_GB=0 _disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
t_assert_eq "0" "$(grep -c -e 'keep-storage' "${BUILDCTL_LOG}" || true)" \
  "0 is the explicit 'reclaim all layer cache' escape hatch"
t_assert_contains "$(cat "${BUILDCTL_LOG}")" "prune --filter type==regular"

t_case "keep-storage adds the records the type==regular filter can never free"
# --keep-storage bounds the WHOLE store; 196 GB of cache mounts against a bare 120000 emptied the layer cache (CON53).
if command -v jq >/dev/null 2>&1; then
  _bk_reset
  BUILDCTL_DU_JSON='[{"id":"a","recordType":"exec.cachemount","size":196000000000,"shared":false},
    {"id":"b","recordType":"source.local","size":2500000000,"shared":false},
    {"id":"c","recordType":"exec.cachemount","size":9000000000,"shared":true},
    {"id":"d","recordType":"regular","size":110000000000,"shared":false}]' \
    _disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
  t_assert_contains "$(cat "${BUILDCTL_LOG}")" "prune --filter type==regular --keep-storage 318500" \
    "120G of layers on top of 198500 MB of cache mounts and sources; shared and regular records do not count"
else
  echo "  (skipped: jq not installed)"
fi

t_case "a garbage keep value falls back to the default instead of reaching buildctl"
# The value reaches arithmetic and --keep-storage, so a typo must not become `000` or a syntax error.
for _bad in "" "abc" "12G" "-5" "10.5"; do
  _bk_reset
  CROSS_BUILDKIT_KEEP_GB="${_bad}" _disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
  t_assert_contains "$(cat "${BUILDCTL_LOG}")" "--keep-storage 120000" \
    "CROSS_BUILDKIT_KEEP_GB='${_bad}' must land on the 120G default"
done

t_case "the once-per-caller credit resets between callers, or the second stage never reclaims"
_bk_reset
_disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
t_assert_eq "1" "$(_bk_prunes)" "first caller prunes"
_bk_reset
_disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
t_assert_eq "1" "$(_bk_prunes)" "a fresh caller must be able to prune again"

t_case "_disk_guard_reclaim_begin is what opens the next episode (DISK2)"
# The latch is a process global, so each chain gate opens its own episode; the sampler's is its whole stage.
_bk_reset
_disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
rm -f "${BUILDCTL_PRUNED}"
_disk_guard_buildkit_fallback "${_bk}/bc" 40 > "${_bk}/o.txt" 2>&1
t_assert_eq "1" "$(_bk_prunes)" "without a new episode the latch still holds"
t_assert_contains "$(cat "${_bk}/o.txt")" "already pruned once here"
_disk_guard_reclaim_begin
_disk_guard_buildkit_fallback "${_bk}/bc" 40 >/dev/null 2>&1
t_assert_eq "2" "$(_bk_prunes)" "a new episode must be able to reach the store again"

t_case "a cache-mount record that did NOT survive is reported loudly"
_bk_reset
BUILDCTL_MOUNTS_AFTER=90 _disk_guard_buildkit_fallback "${_bk}/bc" 40 > "${_bk}/o.txt" 2>&1
t_assert_contains "$(cat "${_bk}/o.txt")" "cache-mount records dropped 97 -> 90"

t_case "a missing buildctl degrades to the old behaviour, it does not die"
_bk_reset
PATH="${_bk}/empty" _disk_guard_buildkit_fallback "${_bk}/bc" 40 > "${_bk}/o.txt" 2>&1
t_assert_contains "$(cat "${_bk}/o.txt")" "SKIP: no buildctl on PATH"
t_assert_eq "0" "$(_bk_prunes)"
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  _disk_guard_free_gb() { echo 4; }
  PATH="'"${_bk}"'/empty" _disk_guard_buildkit_fallback "/" 40 >/dev/null 2>&1
  exit 0'

t_case "an unreachable buildkit socket SKIPs — it must not prune blind"
_bk_reset
BUILDCTL_UNREACHABLE=1 _disk_guard_buildkit_fallback "${_bk}/bc" 40 > "${_bk}/o.txt" 2>&1
t_assert_contains "$(cat "${_bk}/o.txt")" "SKIP: buildkit store unreachable"
t_assert_eq "0" "$(_bk_prunes)" "a store that will not answer du must not be pruned"

t_case "CROSS_BUILDKIT_PRUNE=0 keeps the pre-DISK1 behaviour, and says so"
_bk_reset
CROSS_BUILDKIT_PRUNE=0 _disk_guard_watch_once "${_bk}/bc" 40 "" 3 > "${_bk}/o.txt" 2>&1
t_assert_eq "0" "$(_bk_prunes)"
t_assert_contains "$(cat "${_bk}/o.txt")" "disabled (CROSS_BUILDKIT_PRUNE=0)"
t_assert_contains "$(cat "${_bk}/o.txt")" "NOTHING was reclaimable" \
  "with the fallback off the operator must still get the give-up warning"

t_case "the fallback never aborts the stage it is called from"
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  export CROSS_BUILDKIT_PRUNE=0
  _disk_guard_buildkit_fallback "" "" >/dev/null 2>&1
  _disk_guard_buildkit_fallback "/definitely/not/here" "lots" >/dev/null 2>&1
  _disk_guard_buildkit_fallback "/" 999999 >/dev/null 2>&1
  exit 0'
rm -rf "${_bk}"

# DISK3: the image-store lever, nerdctl stubbed; see docs/build-cache-tiers.md#322-the-image-store-lever-disk3
_im="$(mktemp -d)"
mkdir -p "${_im}/bin" "${_im}/bc"
NERDCTL_LOG="${_im}/nerdctl.log"
export NERDCTL_LOG
cat > "${_im}/bin/nerdctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NERDCTL_LOG}"
if [ "$1" = "images" ]; then
  printf '2026-09-05 12:05:54\tghcr.io/x/y:cross-android-arm64\n'
  printf '2026-09-06 09:00:00\tghcr.io/x/y:cross-media-arm64\n'
  printf '2026-09-07 09:00:00\tghcr.io/x/y:cross-runtime-arm64\n'
  printf '2026-09-07 09:00:00\tghcr.io/x/y:<none>\n'
  printf '2026-09-07 09:00:00\tubuntu:24.04\n'
fi
exit 0
STUB
chmod +x "${_im}/bin/nerdctl"
PATH="${_im}/bin:${PATH}"

# Free space walks up as images are removed: 28G is the number from the incident.
_IM_FREE=28
_disk_guard_free_gb() { printf '%s' "${_IM_FREE}"; }
_im_reset() {
  : > "${NERDCTL_LOG}"; _IM_FREE=28
  _DISK_GUARD_IMAGE_PRUNES=0; _DISK_GUARD_IMAGE_FREED_GB=0; _DISK_GUARD_IMAGE_REMOVED=0
  _DISK_GUARD_TRIM_REMOVED=0; _DISK_GUARD_TRIM_FREED_BYTES=0; _DISK_GUARD_BUILDKIT_FREED_GB=0
}
_im_rmi() { grep -c -e '^rmi ' "${NERDCTL_LOG}" 2>/dev/null || true; }

t_case "a stage IN FLIGHT is refused BY NAME -- the ordering rule, not a preference"
_im_reset
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 1 > "${_im}/o.txt" 2>&1
t_assert_eq "0" "$(_im_rmi)" "removing an image mid-unpack killed the arm64 runtime lane on 2026-09-06"
t_assert_contains "$(cat "${_im}/o.txt")" "a stage is IN FLIGHT"
t_assert_contains "$(cat "${_im}/o.txt")" "Stop the lane, then reclaim."

t_case "the in-stage sampler can never pull this lever"
_im_reset
_disk_guard_watch_once "${_im}/bc" 40 "" 3 > "${_im}/o.txt" 2>&1
t_assert_eq "0" "$(_im_rmi)" "the sampler runs DURING a stage by definition"
t_assert_contains "$(cat "${_im}/o.txt")" "a stage is IN FLIGHT"

t_case "dangling images go first: zero risk, and 20G in the run that found this"
_im_reset
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 > "${_im}/o.txt" 2>&1
t_assert_contains "$(cat "${NERDCTL_LOG}")" "image prune -f"
t_assert_eq "0" "$(grep -c -e 'image prune -a' "${NERDCTL_LOG}" || true)" \
  "-a would take the parents this run pinned"

t_case "protected tags are never candidates, unprotected stage tags are"
_im_reset
_disk_guard_image_store_fallback "${_im}/bc" 120 \
  'ghcr.io/x/y:cross-runtime-arm64
ghcr.io/x/y:cross-media-arm64' 0 > "${_im}/o.txt" 2>&1
t_assert_contains "$(cat "${NERDCTL_LOG}")" "rmi ghcr.io/x/y:cross-android-arm64"
t_assert_eq "0" "$(grep -c -e 'rmi ghcr.io/x/y:cross-runtime-arm64' "${NERDCTL_LOG}" || true)" \
  "the stages still to build, and the one just completed, are the next parents"
t_assert_eq "0" "$(grep -c -e 'rmi ubuntu:24.04' "${NERDCTL_LOG}" || true)" \
  "only this chain's own cross-<stage>-<arch> shape is a candidate"
t_assert_eq "0" "$(grep -c -e 'rmi ghcr.io/x/y:<none>' "${NERDCTL_LOG}" || true)" \
  "an untagged image is the dangling prune's business, not rmi's"

# Bounded: without try-each-tag-once the loop never ends, and a hang stalls the mutation gate.
t_case "a tag that survives its own rmi is tried once, not forever"
_im_reset
timeout 15 bash -c '
  set -u
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  PATH="'"${_im}"'/bin:${PATH}"
  export NERDCTL_LOG="'"${NERDCTL_LOG}"'"
  _disk_guard_free_gb() { printf "28"; }
  _disk_guard_image_store_fallback /tmp 120 "" 0 >/dev/null 2>&1'
t_assert_eq "0" "$?" "the candidate loop must terminate even when rmi changes nothing"
t_assert_eq "3" "$(_im_rmi)" "each of the three cross-* tags is attempted exactly once"

t_case "it stops as soon as the target is reached -- unique layers, not nominal size"
_im_reset
_disk_guard_nerdctl() { _IM_FREE=$(( _IM_FREE + 50 )); command nerdctl "$@"; }
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 > "${_im}/o.txt" 2>&1
t_assert_eq "1" "$(_im_rmi)" "the dangling prune plus ONE removal already cleared 120G"
t_assert_contains "$(cat "${_im}/o.txt")" "freed 50G of unique layers"
_disk_guard_nerdctl() { command nerdctl "$@"; }

t_case "ample free space never reaches nerdctl at all"
_im_reset
_IM_FREE=200
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 > "${_im}/o.txt" 2>&1
t_assert_eq "" "$(cat "${NERDCTL_LOG}")" "a lever that fires above its target is a bug"

t_case "CROSS_IMAGE_PRUNE=0 keeps the pre-DISK3 behaviour, and says so"
_im_reset
CROSS_IMAGE_PRUNE=0 _disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 > "${_im}/o.txt" 2>&1
t_assert_eq "" "$(cat "${NERDCTL_LOG}")"
t_assert_contains "$(cat "${_im}/o.txt")" "disabled (CROSS_IMAGE_PRUNE=0)"

t_case "the give-up warning names the store it did not look in"
_im_reset
_disk_guard_reclaim_record "in-stage" 28 "${_im}/bc" > "${_im}/o.txt" 2>&1
t_assert_contains "$(cat "${_im}/o.txt")" "NOTHING was reclaimable"
t_assert_contains "$(cat "${_im}/o.txt")" "The IMAGE STORE still holds 5 tagged image(s)" \
  "a guard that gives up loudly reads like an environment limit; this one was a coverage gap"
t_assert_contains "$(cat "${_im}/o.txt")" "stop the lane, then reclaim"

t_case "a reclaim that DID free image bytes credits them instead of crying defeat"
_im_reset
_DISK_GUARD_IMAGE_FREED_GB=113
_DISK_GUARD_IMAGE_REMOVED=3
_disk_guard_reclaim_record "between-stages" 28 "${_im}/bc" > "${_im}/o.txt" 2>&1
t_assert_contains "$(cat "${_im}/o.txt")" "+ 113G of image store (3 stage image(s))"
t_assert_eq "0" "$(grep -c -e 'NOTHING was reclaimable' "${_im}/o.txt" || true)"

t_case "the lever runs once per episode, and a new episode re-opens it"
_im_reset
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 >/dev/null 2>&1
: > "${NERDCTL_LOG}"
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 > "${_im}/o.txt" 2>&1
t_assert_eq "" "$(cat "${NERDCTL_LOG}")" "nothing new has been unreferenced since"
t_assert_contains "$(cat "${_im}/o.txt")" "already reclaimed once in this episode"
_disk_guard_reclaim_begin
_disk_guard_image_store_fallback "${_im}/bc" 120 "" 0 >/dev/null 2>&1
t_assert_contains "$(cat "${NERDCTL_LOG}")" "image prune -f" "a fresh episode must be able to reclaim again"

t_case "the lever never aborts the stage it is called from"
t_assert_ok bash -c 'set -euo pipefail
  source "'"${TESTS_DIR}"'/../01-core/disk-guard.sh"
  export CROSS_IMAGE_PRUNE=0
  _disk_guard_image_store_fallback "" "" "" 0 >/dev/null 2>&1
  _disk_guard_image_store_fallback "/definitely/not/here" "lots" "" 0 >/dev/null 2>&1
  _disk_guard_image_store_fallback "/" 999999 "" 1 >/dev/null 2>&1
  exit 0'
rm -rf "${_im}"

t_summary
