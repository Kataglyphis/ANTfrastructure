#!/usr/bin/env bash
# disk-guard.sh — pure helpers for the between-stage disk safety valve in
# build-cross-chain.sh (_chain_stage_disk_guard). Split out so they are unit-
# testable: build-cross-chain.sh executes main on load and cannot be sourced.
#
# Provides:
#   _disk_guard_free_gb <path>                        — free GB on path's own fs
#   _disk_guard_pick_victim <bc_dir> <protected_csv>  — oldest prunable slug
#   _disk_guard_protected_slugs <completed_stage>     — slugs of remaining stages
#   _disk_guard_watch_once / _disk_guard_watch_loop   — in-stage sampling (B2)
#   _disk_guard_runtime_lane_need_gb                  — runtime-lane free-GB need
#   _disk_guard_buildkit_fallback <path> <target_gb>  — filtered buildkit prune (DISK1)
#   _disk_guard_reclaim_begin                         — opens one reclaim episode
#
# _disk_guard_protected_slugs expects the caller's environment to provide the
# stage graph (CROSS_STAGE_ORDER, stage_enabled, cross_stage_is_per_arch,
# cross_stage_tag, arch_list_to_words, TARGET_ARCHES) — in production that is
# lib-orchestrator.sh; tests stub them.
[ -n "${_DISK_GUARD_SH_LOADED:-}" ] && return 0
_DISK_GUARD_SH_LOADED=1

# Free gibibytes on the filesystem that actually holds <path>.
#
# WHY NOT `df "${path%/*}"`: that reads the PARENT directory, which is a
# different filesystem whenever the path itself is a mountpoint — e.g. a
# dedicated cache volume at ~/.cache/kata-buildcache would report the free
# space of ~/.cache's device instead. The disk preflight exists to prevent a
# multi-hour ENOSPC death, so measuring the wrong device defeats it entirely.
#
# `df` also fails outright on a not-yet-created directory (first run), so walk
# up to the deepest EXISTING ancestor and measure there — same filesystem the
# path will land on once mkdir'd. Prints nothing when df is unusable; callers
# treat empty as "unknown, skip the check".
_disk_guard_free_gb() {
  local probe="${1:-}"
  [ -n "${probe}" ] || probe="/"
  while [ ! -e "${probe}" ]; do
    case "${probe}" in
      */*) probe="${probe%/*}"; [ -n "${probe}" ] || probe="/" ;;
      *)   probe="."; break ;;
    esac
  done
  # `|| true`: callers run under `set -euo pipefail`, where a failing df would
  # propagate through pipefail and abort the whole orchestrator on what is only
  # a "cannot determine free space" condition. Empty output means unknown.
  df -BG --output=avail "${probe}" 2>/dev/null | tail -1 | tr -dc '0-9' || true
}

# Oldest-mtime slug dir under $1 whose name is not in the comma-separated
# protected list $2 (empty output = nothing prunable).
_disk_guard_pick_victim() {
  local bc_dir="$1" protected_csv="$2" name
  [ -d "${bc_dir}" ] || return 0
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    case ",${protected_csv}," in *",${name},"*) continue ;; esac
    printf '%s\n' "${name}"
    return 0
  done < <(ls -1tr "${bc_dir}" 2>/dev/null)
  return 0
}

# Image tags, one per line, for the stages after $1 in CROSS_STAGE_ORDER that are
# enabled in this run. $2=1 also emits $1's OWN tag -- the next stage's parent,
# which the local OCI handoff reads from the image store. Empty $1 = unknown
# position, so every enabled stage is named.
_disk_guard_stage_tags() {
  local completed_stage="$1" include_completed="${2:-0}" s arch tag
  local seen_completed=0
  [ -n "${completed_stage}" ] || seen_completed=1
  for s in "${CROSS_STAGE_ORDER[@]}"; do
    if [ "${seen_completed}" -eq 0 ]; then
      if [ "${s}" = "${completed_stage}" ]; then
        seen_completed=1
        [ "${include_completed}" = "1" ] || continue
      else
        continue
      fi
    fi
    stage_enabled "${s}" || continue
    if cross_stage_is_per_arch "${s}"; then
      for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
        tag="$(cross_stage_tag "${s}" "${arch}" 2>/dev/null || true)"
        [ -n "${tag}" ] && printf '%s\n' "${tag}"
      done
    else
      tag="$(cross_stage_tag "${s}" 2>/dev/null || true)"
      [ -n "${tag}" ] && printf '%s\n' "${tag}"
    fi
  done
  # LOAD-BEARING: the last `[ -n ]` may be false, and an unguarded conditional as
  # the final command returns 1 -- which trips errexit in every caller.
  return 0
}

# Comma-separated cache slugs for those same stages (same tag→slug mapping as
# cross-stage-build.sh: tag with /:@ mapped to _).
_disk_guard_protected_slugs() {
  local tag out=""
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    out+="${out:+,}$(printf '%s' "${tag}" | tr '/:@' '___')"
  done < <(_disk_guard_stage_tags "$1" 0)
  printf '%s' "${out}"
}

# ── D4: free-space-driven trim of the cache-export dir (kata-buildcache) ──
# Policy, knobs and why this is safe: docs/build-cache-tiers.md ("Preflight
# trim"). It touches ONLY that host directory — never the buildkit store.

# log() when the caller has logging.sh, plain stdout otherwise (unit tests).
_disk_guard_log() {
  if declare -F log >/dev/null 2>&1; then log "$@"; else printf '[INFO] %s\n' "$*"; fi
}

# Disk usage of <dir> in bytes; empty when du cannot read it.
_disk_guard_dir_bytes() {
  # `|| true`: callers run under pipefail, where a failing du would abort them.
  du -s --block-size=1 "${1:-}" 2>/dev/null | cut -f1 | tr -dc '0-9' || true
}

_disk_guard_fmt_gib() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f", b/1073741824}'
}

# _disk_guard_trim_cache_export <bc_dir> <target_free_gb> [protected_csv] [budget_bytes]
#
# Removes OLDEST-first slug dirs until free space reaches <target_free_gb> or
# <budget_bytes> has been reclaimed — the budget is what stops it degenerating
# into `rm -rf ${bc_dir}/*` when something else is eating the disk. No-op when
# free space is already ample or unknown. Always returns 0: a trim that cannot
# help must not abort the chain.
# Sets globals _DISK_GUARD_TRIM_FREED_BYTES / _DISK_GUARD_TRIM_REMOVED, so call
# it directly — a $(...) subshell would discard both.
_DISK_GUARD_TRIM_FREED_BYTES=0
_DISK_GUARD_TRIM_REMOVED=0
_disk_guard_trim_cache_export() {
  local bc_dir="${1:-}" target_gb="${2:-}" protected="${3:-}" budget_bytes="${4:-}"
  # keep_n: never remove the newest N slugs. Without it the budget does NOT bound
  # the trim -- when the deficit exceeds the whole directory (the common case)
  # the loop runs until pick_victim is dry and wipes it. docs/build-cache-tiers.md
  local keep_n="${5:-3}"
  case "${keep_n}" in ''|*[!0-9]*) keep_n=3 ;; esac
  _DISK_GUARD_TRIM_FREED_BYTES=0
  _DISK_GUARD_TRIM_REMOVED=0
  [ -n "${bc_dir}" ] && [ -d "${bc_dir}" ] || return 0
  case "${target_gb}" in ''|*[!0-9]*) return 0 ;; esac

  local free_gb
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0                    # unknown -> do nothing
  [ "${free_gb}" -lt "${target_gb}" ] || return 0    # ample -> no-op

  [ -n "${budget_bytes}" ] || budget_bytes=$(( (target_gb - free_gb) * 1073741824 ))
  case "${budget_bytes}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${budget_bytes}" -gt 0 ] || return 0

  _disk_guard_log "[disk-trim] ${free_gb}G free < ${target_gb}G needed — reclaiming up to $(_disk_guard_fmt_gib "${budget_bytes}") GiB of regenerable cache exports in ${bc_dir} (oldest first; protected: ${protected:-none})"
  local victim sz
  local remaining
  while [ "${_DISK_GUARD_TRIM_FREED_BYTES}" -lt "${budget_bytes}" ]; do
    remaining="$(find "${bc_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    if [ "${remaining}" -le "${keep_n}" ]; then
      _disk_guard_log "[disk-trim]   keeping the newest ${keep_n} slug(s); stopping"
      break
    fi
    victim="$(_disk_guard_pick_victim "${bc_dir}" "${protected}")"
    [ -n "${victim}" ] || break
    sz="$(_disk_guard_dir_bytes "${bc_dir}/${victim}")"
    [ -n "${sz}" ] || sz=0
    rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
    # Undeletable victim would be re-picked forever: report and stop.
    if [ -e "${bc_dir}/${victim}" ]; then
      _disk_guard_log "[disk-trim]   SKIP ${victim} — could not remove; stopping"
      break
    fi
    _DISK_GUARD_TRIM_FREED_BYTES=$(( _DISK_GUARD_TRIM_FREED_BYTES + sz ))
    _DISK_GUARD_TRIM_REMOVED=$(( _DISK_GUARD_TRIM_REMOVED + 1 ))
    _disk_guard_log "[disk-trim]   removed ${victim} ($(_disk_guard_fmt_gib "${sz}") GiB)"
    free_gb="$(_disk_guard_free_gb "${bc_dir}")"
    if [ -z "${free_gb}" ] || [ "${free_gb}" -ge "${target_gb}" ]; then break; fi
  done
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  _disk_guard_log "[disk-trim] removed ${_DISK_GUARD_TRIM_REMOVED} slug(s), freed $(_disk_guard_fmt_gib "${_DISK_GUARD_TRIM_FREED_BYTES}") GiB; ${free_gb:-?}G free now"
  return 0
}

# ── B2/B3: in-stage sampling + a greppable record of every chain reclaim ──
# Why a watchdog, and where the numbers come from: docs/build-cache-tiers.md § 3.2.

# warn() when the caller has logging.sh, plain stderr otherwise (unit tests).
_disk_guard_warn() {
  if declare -F warn >/dev/null 2>&1; then warn "$@"; else printf '[WARN] %s\n' "$*" >&2; fi
}

# ── DISK1: filtered buildkit-store fallback when the trim cannot free enough ──
# Keep-storage policy, the once-per-caller rule, the log contract and the
# unfiltered-prune incident this must never repeat:
# docs/build-cache-tiers.md#321-the-buildkit-store-fallback-disk1
_DISK_GUARD_BUILDKIT_FREED_GB=0
_DISK_GUARD_BUILDKIT_PRUNES=0

# Open a reclaim episode: the once-per-caller credit is per EPISODE, not per run.
# The sampler's episode is one whole stage, so it never calls this; a gate whose
# episode is one invocation calls it first, or the second gate of a chain finds
# the credit spent by the first and refuses a prune hours later.
_disk_guard_reclaim_begin() {
  _DISK_GUARD_BUILDKIT_PRUNES=0
  _DISK_GUARD_BUILDKIT_FREED_GB=0
  _DISK_GUARD_IMAGE_PRUNES=0
  _DISK_GUARD_IMAGE_FREED_GB=0
  _DISK_GUARD_IMAGE_REMOVED=0
}

_disk_guard_buildctl() {
  BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/user/$(id -u)/buildkit/buildkitd.sock}" buildctl "$@"
}

# exec.cachemount record count; 0 when the store cannot be read.
_disk_guard_cachemount_count() {
  # `|| true`: grep -c exits 1 on no match and callers run under pipefail.
  _disk_guard_buildctl du --filter type==exec.cachemount 2>/dev/null | grep -c . || true
}

_disk_guard_keep_gb() {
  local keep="${CROSS_BUILDKIT_KEEP_GB:-120}"
  case "${keep}" in ''|*[!0-9]*) keep=120 ;; esac
  if [ "${keep}" -gt 0 ] && [ "${keep}" -lt 100 ]; then keep=100; fi
  printf '%s' "${keep}"
}

# May the fallback run? Every refusal names itself in the log — a silent skip is
# indistinguishable from the 2026-09-03 "NOTHING was reclaimable" it replaces.
# Should a lever fire at all? Prints the free GB when <path> is BELOW <target_gb>
# and returns non-zero otherwise -- an unparseable target, an unreadable df and
# ample space are all "do nothing", and a lever that fires above its target is a
# bug in every tier.
_disk_guard_lever_needed() {
  local before
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  before="$(_disk_guard_free_gb "${1:-}")"
  [ -n "${before}" ] || return 1
  [ "${before}" -lt "$2" ] || return 1
  printf '%s' "${before}"
}

# The three preconditions BOTH levers share, in one place: the operator knob, the
# once-per-episode latch, and the tool the lever shells out to. Every refusal
# names itself and says which store it left alone -- a silent skip is
# indistinguishable from the "NOTHING was reclaimable" both levers exist to end.
# $1=log tag  $2=knob name  $3=knob value  $4=prunes so far  $5=latch reason
# $6=tool  $7=hand-reclaim hint  $8=store noun
_disk_guard_lever_ready() {
  local tag="$1" knob="$2" val="$3" prunes="$4" latch_why="$5" tool="$6" hint="$7" store="$8"

  if [ "${val}" != "1" ]; then
    _disk_guard_log "[${tag}] disabled (${knob}=${val}) — the ${store} is not touched"
    return 1
  fi
  if [ "${prunes:-0}" -gt 0 ]; then
    _disk_guard_log "[${tag}] ${latch_why}"
    return 1
  fi
  if ! command -v "${tool}" >/dev/null 2>&1; then
    _disk_guard_warn "[${tag}] SKIP: no ${tool} on PATH — ${hint}"
    return 1
  fi
  return 0
}

_disk_guard_buildkit_ready() {
  _disk_guard_lever_ready disk-buildkit \
    CROSS_BUILDKIT_PRUNE "${CROSS_BUILDKIT_PRUNE:-1}" \
    "${_DISK_GUARD_BUILDKIT_PRUNES:-0}" \
    "already pruned once here — the store is at keep-storage, a repeat walk costs I/O and frees nothing" \
    buildctl "reclaim by hand with linux/host-config/prune-safe.sh" \
    "buildkit store" || return 1
  # Only this lever can ask its store whether it is even reachable.
  if ! _disk_guard_buildctl du >/dev/null 2>&1; then
    _disk_guard_warn "[disk-buildkit] SKIP: buildkit store unreachable — reclaim by hand with linux/host-config/prune-safe.sh"
    return 1
  fi
  return 0
}

_disk_guard_buildkit_prune() {
  local keep="${1:-0}"
  if [ "${keep}" -gt 0 ]; then
    _disk_guard_buildctl prune --filter type==regular --keep-storage "$(( keep * 1000 ))" >/dev/null 2>&1
  else
    _disk_guard_buildctl prune --filter type==regular >/dev/null 2>&1
  fi
}

_disk_guard_cachemount_verdict() {
  if [ "${2:-0}" -lt "${1:-0}" ]; then
    _disk_guard_warn "[disk-buildkit] cache-mount records dropped ${1} -> ${2} — the type==regular filter did not hold; ccache/sccache/uv are gone and the next compile stage runs COLD"
  else
    _disk_guard_log "[disk-buildkit] all ${2} cache-mount record(s) survived"
  fi
}

# _disk_guard_buildkit_fallback <path> <target_gb>
# Runs only when <path> is STILL below <target_gb> after the cache-export trim.
# Always returns 0: a reclaim that cannot run must not abort the stage.
_disk_guard_buildkit_fallback() {
  local path="${1:-}" target_gb="${2:-}" keep n_before n_after before after t0
  _DISK_GUARD_BUILDKIT_FREED_GB=0
  before="$(_disk_guard_lever_needed "${path}" "${target_gb}")" || return 0
  _disk_guard_buildkit_ready || return 0
  keep="$(_disk_guard_keep_gb)"
  n_before="$(_disk_guard_cachemount_count)"
  t0="${SECONDS}"
  _disk_guard_log "[disk-buildkit] ${before}G free < ${target_gb}G after the cache-export trim — pruning type==regular layer cache with --keep-storage ${keep}G (exec.cachemount records are not candidates)"
  _disk_guard_buildkit_prune "${keep}" || true
  _DISK_GUARD_BUILDKIT_PRUNES=$(( ${_DISK_GUARD_BUILDKIT_PRUNES:-0} + 1 ))
  after="$(_disk_guard_free_gb "${path}")"
  n_after="$(_disk_guard_cachemount_count)"
  if [ -n "${after}" ] && [ "${after}" -gt "${before}" ]; then
    _DISK_GUARD_BUILDKIT_FREED_GB=$(( after - before ))
  fi
  _disk_guard_log "[disk-buildkit] reclaimed ${_DISK_GUARD_BUILDKIT_FREED_GB}G of layer cache in $(( SECONDS - t0 ))s (${before}G -> ${after:-?}G free; keep-storage ${keep}G)"
  _disk_guard_cachemount_verdict "${n_before:-0}" "${n_after:-0}"
  return 0
}

# ── DISK3: the third store, the one the guard could not see ──────────────────
# 2026-09-05: "NOTHING was reclaimable" at 28G free while ~/.local/share/containerd
# held 295 GB. ORDERING, not preference: `buildctl prune` never touches the image
# store and is safe mid-stage, but removing IMAGES is safe only when nothing is in
# flight — it killed the arm64 runtime lane on 2026-09-06 — so this lever refuses,
# by name, whenever its caller says a stage is running.
# docs/build-cache-tiers.md#322-the-image-store-lever-disk3
_DISK_GUARD_IMAGE_FREED_GB=0
_DISK_GUARD_IMAGE_REMOVED=0
_DISK_GUARD_IMAGE_PRUNES=0

_disk_guard_nerdctl() { nerdctl "$@"; }

# Local image tags of this chain's own stage shape, newest first (nerdctl prints
# CreatedAt, which sorts lexically), minus every protected tag. One per line.
_disk_guard_image_candidates() {
  local protected_nl="$1" line tag
  _disk_guard_nerdctl images --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | sort -r \
    | while IFS= read -r line; do
        tag="${line#*$'\t'}"
        case "${tag}" in *:cross-*) ;; *) continue ;; esac
        case "${tag}" in *"<none>"*) continue ;; esac
        printf '%s\n' "${protected_nl}" | grep -qxF -- "${tag}" && continue
        printf '%s\n' "${tag}"
      done
}

# May the image lever run? Every refusal names itself: a silent skip is the
# "NOTHING was reclaimable" this whole entry is about.
_disk_guard_image_ready() {
  local in_flight="${1:-0}"
  if [ "${in_flight}" = "1" ]; then
    _disk_guard_warn "[disk-images] SKIP: a stage is IN FLIGHT — removing an image now can pull a blob out from under an 'unpacking overlayfs' (it killed the arm64 runtime lane on 2026-09-06). Stop the lane, then reclaim."
    return 1
  fi
  _disk_guard_lever_ready disk-images \
    CROSS_IMAGE_PRUNE "${CROSS_IMAGE_PRUNE:-1}" \
    "${_DISK_GUARD_IMAGE_PRUNES:-0}" \
    "already reclaimed once in this episode — nothing new has been unreferenced since" \
    nerdctl "reclaim by hand (nerdctl image prune, then the stage tags this run does not need)" \
    "image store"
}

# _disk_guard_image_store_fallback <path> <target_gb> <protected_tags_nl> [stage_in_flight]
# Runs only when <path> is STILL below <target_gb> after the buildkit fallback.
# Two steps, in risk order: dangling images (zero risk, 20 GB in the 2026-09-05
# run), then this chain's own stage tags that the rest of the run does not need.
# Never the current run's parents, and never the whole-system form — see
# [[rebuild-disk-management]] for why the cachemounts must survive.
# Always returns 0: a reclaim that cannot run must not abort the stage.
_disk_guard_image_store_fallback() {
  local path="${1:-}" target_gb="${2:-}" protected="${3:-}" in_flight="${4:-0}"
  local before after step tag freed t0
  _DISK_GUARD_IMAGE_FREED_GB=0
  _DISK_GUARD_IMAGE_REMOVED=0
  before="$(_disk_guard_lever_needed "${path}" "${target_gb}")" || return 0
  _disk_guard_image_ready "${in_flight}" || return 0
  _DISK_GUARD_IMAGE_PRUNES=$(( ${_DISK_GUARD_IMAGE_PRUNES:-0} + 1 ))
  t0="${SECONDS}"

  _disk_guard_log "[disk-images] ${before}G free < ${target_gb}G after the buildkit prune — removing dangling images first"
  _disk_guard_nerdctl image prune -f >/dev/null 2>&1 || true
  step="$(_disk_guard_free_gb "${path}")"
  [ -n "${step}" ] || step="${before}"
  _disk_guard_log "[disk-images] dangling images: ${before}G -> ${step}G free"

  # SIZE IS NOT THE METRIC, unique layers are: deleting the three cross-sdk-*
  # images (80 GB by `nerdctl images`) freed ZERO bytes, because every layer they
  # hold is also held by the cross-android-* images built on top of them. So this
  # measures free space after each removal instead of ranking by nominal size.
  # Bounded by construction as well as by the protected set below: a loop whose
  # only stop condition is bookkeeping HANGS when the bookkeeping is wrong, and a
  # hung guard inside a chain is worse than one that gives up early.
  local guard=0
  while [ "${step}" -lt "${target_gb}" ] && [ "${guard}" -lt "${_DISK_GUARD_IMAGE_MAX_REMOVALS:-50}" ]; do
    guard=$(( guard + 1 ))
    tag="$(_disk_guard_image_candidates "${protected}" | head -1)"
    [ -n "${tag}" ] || break
    # A tag still listed after its own rmi -- untagged rather than deleted, or a
    # removal that quietly did nothing -- would be the head of the list forever.
    # Every ATTEMPTED tag joins the protected set, so each is tried at most once;
    # the cache-export victim loop guards the same spin the same way.
    protected="${protected}
${tag}"
    _disk_guard_nerdctl rmi "${tag}" >/dev/null 2>&1 || {
      _disk_guard_warn "[disk-images]   ${tag} would not remove (in use?); leaving it"
      continue
    }
    _DISK_GUARD_IMAGE_REMOVED=$(( _DISK_GUARD_IMAGE_REMOVED + 1 ))
    after="$(_disk_guard_free_gb "${path}")"
    [ -n "${after}" ] || break
    freed=$(( after - step ))
    _disk_guard_log "[disk-images]   removed ${tag} — freed ${freed}G of unique layers (${after}G free)"
    step="${after}"
  done

  after="$(_disk_guard_free_gb "${path}")"
  if [ -n "${after}" ] && [ "${after}" -gt "${before}" ]; then
    _DISK_GUARD_IMAGE_FREED_GB=$(( after - before ))
  fi
  _disk_guard_log "[disk-images] reclaimed ${_DISK_GUARD_IMAGE_FREED_GB}G from the image store in $(( SECONDS - t0 ))s (${_DISK_GUARD_IMAGE_REMOVED} stage image(s) + dangling; ${before}G -> ${after:-?}G free)"
  return 0
}

# One greppable line per reclaim the chain performs — including the reclaim that
# freed nothing, which is the case an operator most needs to see.
# _disk_guard_reclaim_record <where> <free_gb_before> <bc_dir>
_disk_guard_reclaim_record() {
  local where="${1:-?}" before_gb="${2:-?}" bc_dir="${3:-}" after_gb bk="" im=""
  after_gb="$(_disk_guard_free_gb "${bc_dir}")"
  if [ "${_DISK_GUARD_BUILDKIT_FREED_GB:-0}" -gt 0 ] 2>/dev/null; then
    bk=" + ${_DISK_GUARD_BUILDKIT_FREED_GB}G of buildkit layer cache"
  fi
  if [ "${_DISK_GUARD_IMAGE_FREED_GB:-0}" -gt 0 ] 2>/dev/null; then
    im=" + ${_DISK_GUARD_IMAGE_FREED_GB}G of image store (${_DISK_GUARD_IMAGE_REMOVED:-0} stage image(s))"
  fi
  if [ "${_DISK_GUARD_TRIM_REMOVED:-0}" -gt 0 ] 2>/dev/null || [ -n "${bk}" ] || [ -n "${im}" ]; then
    _disk_guard_log "[disk-reclaim] ${where}: removed ${_DISK_GUARD_TRIM_REMOVED} cache-export slug(s), freed $(_disk_guard_fmt_gib "${_DISK_GUARD_TRIM_FREED_BYTES:-0}") GiB${bk}${im}; ${before_gb}G -> ${after_gb:-?}G free"
  else
    _disk_guard_warn "[disk-reclaim] ${where}: NOTHING was reclaimable (${before_gb}G -> ${after_gb:-?}G free) — the chain cannot free more space by itself. $(_disk_guard_image_store_hint)"
  fi
}

# What the operator can still do that the chain will not do for them. A guard
# that gives up loudly reads like an environment limit; on 2026-09-05 it was a
# coverage gap -- 295 GB sat in the image store while this line said "nothing".
_disk_guard_image_store_hint() {
  local n=""
  if command -v nerdctl >/dev/null 2>&1; then
    n="$(_disk_guard_nerdctl images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -c . || true)"
  fi
  if [ -n "${n}" ] && [ "${n}" -gt 0 ] 2>/dev/null; then
    printf '%s' "The IMAGE STORE still holds ${n} tagged image(s) and this guard will not touch it while a lane runs: stop the lane, then reclaim (nerdctl image prune, then the cross-* stage tags this run does not need). Free some or the build will ENOSPC"
  else
    printf '%s' "Free some or the build will ENOSPC"
  fi
}

# One sample of the cache dir's filesystem, plus a reclaim when it is below
# <threshold_gb>. Always returns 0 — a sampler must never abort a build.
# _disk_guard_watch_once <bc_dir> <threshold_gb> [protected_csv] [keep_n]
_disk_guard_watch_once() {
  local bc_dir="${1:-}" threshold="${2:-}" protected="${3:-}" keep_n="${4:-3}"
  case "${threshold}" in ''|*[!0-9]*) return 0 ;; esac
  local free_gb
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0
  _disk_guard_log "[disk-watch] ${free_gb}G free on ${bc_dir}"
  [ "${free_gb}" -lt "${threshold}" ] || return 0
  _disk_guard_warn "[disk-watch] ${free_gb}G free < ${threshold}G DURING a stage — reclaiming regenerable cache exports now"
  _disk_guard_trim_cache_export "${bc_dir}" "${threshold}" "${protected}" "" "${keep_n}"
  _disk_guard_buildkit_fallback "${bc_dir}" "${threshold}"
  # in_flight=1 by definition here: this sampler runs DURING a stage, which is
  # the one time the image lever must not be pulled (DISK3's ordering rule).
  _disk_guard_image_store_fallback "${bc_dir}" "${threshold}" "" 1
  _disk_guard_reclaim_record "in-stage" "${free_gb}" "${bc_dir}"
  return 0
}

# The sampling loop the orchestrator backgrounds for the runtime lane. Runs
# until killed; _DISK_GUARD_WATCH_MAX_ITERS bounds it for the unit tests.
# _disk_guard_watch_loop <bc_dir> <threshold_gb> <interval_s> [protected_csv] [keep_n]
_disk_guard_watch_loop() {
  local bc_dir="${1:-}" threshold="${2:-}" interval="${3:-120}"
  local protected="${4:-}" keep_n="${5:-3}"
  # Die with the owner. Without this the backgrounded watchdog outlives a parent
  # that was killed without running its traps, and keeps trimming forever.
  local owner="${6:-$PPID}"
  case "${interval}" in ''|*[!0-9]*) interval=120 ;; esac
  [ "${interval}" -ge 1 ] || interval=1
  local max="${_DISK_GUARD_WATCH_MAX_ITERS:-0}" i=0
  case "${max}" in ''|*[!0-9]*) max=0 ;; esac
  while :; do
    sleep "${interval}" || return 0
    kill -0 "${owner}" 2>/dev/null || return 0
    _disk_guard_watch_once "${bc_dir}" "${threshold}" "${protected}" "${keep_n}" || true
    i=$(( i + 1 ))
    if [ "${max}" -gt 0 ] && [ "${i}" -ge "${max}" ]; then return 0; fi
  done
}

# Free GB the runtime lane needs: ~120 GB per wrapper build, and arches are
# sequential unless --parallel-archs — so scale by CONCURRENCY, not arch count.
# _disk_guard_runtime_lane_need_gb <per_arch_gb> <n_arch> <parallel 0|1>
_disk_guard_runtime_lane_need_gb() {
  local per_arch="${1:-120}" n_arch="${2:-1}" parallel="${3:-0}" conc=1
  case "${per_arch}" in ''|*[!0-9]*) per_arch=120 ;; esac
  case "${n_arch}" in ''|*[!0-9]*) n_arch=1 ;; esac
  [ "${n_arch}" -ge 1 ] || n_arch=1
  [ "${parallel}" = "1" ] && conc="${n_arch}"
  printf '%s' $(( per_arch * conc ))
}
