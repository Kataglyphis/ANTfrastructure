#!/usr/bin/env bash
# disk-guard.sh — pure helpers for the between-stage disk safety valve in
# build-cross-chain.sh (_chain_stage_disk_guard). Split out so they are unit-
# testable: build-cross-chain.sh executes main on load and cannot be sourced.
#
# Provides:
#   _disk_guard_pick_victim <bc_dir> <protected_csv>  — oldest prunable slug
#   _disk_guard_protected_slugs <completed_stage>     — slugs of remaining stages
#
# _disk_guard_protected_slugs expects the caller's environment to provide the
# stage graph (CROSS_STAGE_ORDER, stage_enabled, cross_stage_is_per_arch,
# cross_stage_tag, arch_list_to_words, TARGET_ARCHES) — in production that is
# lib-orchestrator.sh; tests stub them.
[ -n "${_DISK_GUARD_SH_LOADED:-}" ] && return 0
_DISK_GUARD_SH_LOADED=1

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
