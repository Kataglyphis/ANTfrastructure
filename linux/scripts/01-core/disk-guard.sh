#!/usr/bin/env bash
# disk-guard.sh — pure helpers for the between-stage disk safety valve in
# build-cross-chain.sh (_chain_stage_disk_guard). Split out so they are unit-
# testable: build-cross-chain.sh executes main on load and cannot be sourced.
#
# Provides:
#   _disk_guard_free_gb <path>                        — free GB on path's own fs
#   _disk_guard_pick_victim <bc_dir> <protected_csv>  — oldest prunable slug
#   _disk_guard_protected_slugs <completed_stage>     — slugs of remaining stages
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
