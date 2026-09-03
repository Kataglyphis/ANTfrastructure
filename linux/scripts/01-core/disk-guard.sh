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

# Comma-separated cache slugs for the stages after $1 in CROSS_STAGE_ORDER that
# are enabled in this run (same tag→slug mapping as cross-stage-build.sh:
# tag with /:@ mapped to _). Empty $1 = unknown position → protect all enabled.
_disk_guard_protected_slugs() {
  local completed_stage="$1" s arch tag out=""
  local seen_completed=0
  [ -n "${completed_stage}" ] || seen_completed=1
  for s in "${CROSS_STAGE_ORDER[@]}"; do
    if [ "${seen_completed}" -eq 0 ]; then
      [ "${s}" = "${completed_stage}" ] && seen_completed=1
      continue
    fi
    stage_enabled "${s}" || continue
    if cross_stage_is_per_arch "${s}"; then
      for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
        tag="$(cross_stage_tag "${s}" "${arch}" 2>/dev/null || true)"
        [ -n "${tag}" ] && out+="${out:+,}$(printf '%s' "${tag}" | tr '/:@' '___')"
      done
    else
      tag="$(cross_stage_tag "${s}" 2>/dev/null || true)"
      [ -n "${tag}" ] && out+="${out:+,}$(printf '%s' "${tag}" | tr '/:@' '___')"
    fi
  done
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

# One greppable line per reclaim the chain performs — including the reclaim that
# freed nothing, which is the case an operator most needs to see.
# _disk_guard_reclaim_record <where> <free_gb_before> <bc_dir>
_disk_guard_reclaim_record() {
  local where="${1:-?}" before_gb="${2:-?}" bc_dir="${3:-}" after_gb
  after_gb="$(_disk_guard_free_gb "${bc_dir}")"
  if [ "${_DISK_GUARD_TRIM_REMOVED:-0}" -gt 0 ] 2>/dev/null; then
    _disk_guard_log "[disk-reclaim] ${where}: removed ${_DISK_GUARD_TRIM_REMOVED} cache-export slug(s), freed $(_disk_guard_fmt_gib "${_DISK_GUARD_TRIM_FREED_BYTES:-0}") GiB; ${before_gb}G -> ${after_gb:-?}G free"
  else
    _disk_guard_warn "[disk-reclaim] ${where}: NOTHING was reclaimable (${before_gb}G -> ${after_gb:-?}G free) — the chain cannot free more space by itself; free some or the build will ENOSPC"
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
