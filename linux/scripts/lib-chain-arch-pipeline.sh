#!/usr/bin/env bash
# One pipeline per arch through the per-arch stages, behind CROSS_ARCH_PIPELINE. docs/linux-cross-builds.md#one-pipeline-per-arch
[ -n "${_LIB_CHAIN_ARCH_PIPELINE_LOADED:-}" ] && return 0
_LIB_CHAIN_ARCH_PIPELINE_LOADED=1

# A typo must stop the chain at its start, and PARALLEL_STAGES names a join this mode does not have.
chain_arch_pipeline_validate() {
  case "${CROSS_ARCH_PIPELINE:-0}" in
    0) return 0 ;;
    1) ;;
    *) warn "CROSS_ARCH_PIPELINE must be 0 or 1, not ${CROSS_ARCH_PIPELINE}"; return 2 ;;
  esac
  if [ "${PARALLEL_STAGES:-all}" != "all" ]; then
    warn "CROSS_ARCH_PIPELINE=1 runs every per-arch stage in its arch's lane; PARALLEL_STAGES=${PARALLEL_STAGES} cannot apply"
    return 2
  fi
  return 0
}

chain_arch_pipeline_on() {
  if [ "${CROSS_ARCH_PIPELINE:-0}" = "1" ]; then return 0; fi
  return 1
}

# Fills the caller's stages and arches arrays.
_chain_pipeline_lists() {
  mapfile -t stages < <(_chain_arch_pipeline_stages)
  mapfile -t arches < <(arch_list_to_words "${TARGET_ARCHES}")
}

_chain_arch_pipeline_stages() {
  local stage
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    if stage_enabled "${stage}" && cross_stage_is_per_arch "${stage}"; then
      printf '%s\n' "${stage}"
    fi
  done
}

# The stages a finished arch no longer needs: the runtime lane reads only its last one.
_chain_lane_finished_tags() {
  local state="$1" arch stage tag
  local -a stages=() arches=()
  _chain_pipeline_lists
  unset 'stages[-1]'
  for arch in "${arches[@]}"; do
    [ -f "${state}/lane-done.${arch}" ] || continue
    for stage in "${stages[@]}"; do
      tag="$(cross_stage_tag "${stage}" "${arch}" 2>/dev/null || true)"
      [ -z "${tag}" ] || printf '%s\n' "${tag}"
    done
  done
  return 0
}

# Named tags of finished arches only: a dangling prune took a blob from a running handoff. docs/build-cache-tiers.md#322-the-image-store-lever-disk3
_chain_lane_image_lever() {
  local state="$1" bc_dir="$2" target="$3" tag free_gb
  [ "${CROSS_IMAGE_PRUNE:-1}" != "0" ] || return 0
  while IFS= read -r tag; do
    free_gb="$(_disk_guard_free_gb "${bc_dir}")"
    [ -n "${free_gb}" ] && [ "${free_gb}" -lt "${target}" ] || return 0
    if _disk_guard_nerdctl rmi "${tag}" >/dev/null 2>&1; then
      log "[disk-lane] removed ${tag} of a finished arch; $(_disk_guard_free_gb "${bc_dir}")G free"
    else
      warn "[disk-lane] ${tag} would not remove; leaving it"
    fi
  done < <(_chain_lane_finished_tags "${state}")
  return 0
}

# An unreadable free space reclaims nothing: nothing could measure whether it helped.
_chain_lane_below() {
  local free_gb
  free_gb="$(_disk_guard_free_gb "$1")"
  if [ -n "${free_gb}" ] && [ "${free_gb}" -lt "$2" ]; then return 0; fi
  return 1
}

# Runs under the state lock; the free space is read again because the previous holder may have freed enough.
_chain_lane_reclaim() {
  local stage="$1" arch="$2" state="$3" bc_dir="$4" threshold="$5" free_gb protected
  _chain_lane_below "${bc_dir}" "${threshold}" || return 0
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  protected="$(_disk_guard_protected_slugs '')"
  log "[disk-lane] ${free_gb}G free < ${threshold}G after ${stage}-${arch}, with other arches building (protected: ${protected:-none})"
  _disk_guard_reclaim_begin
  local before="${free_gb}"
  _chain_evict_slugs "${bc_dir}" protected _chain_bc_free_gb _chain_num_below "${threshold}" free_gb
  _disk_guard_buildkit_fallback "${bc_dir}" "${threshold}"
  _chain_lane_image_lever "${state}" "${bc_dir}" "${threshold}"
  _disk_guard_reclaim_record "lane-${stage}-${arch}" "${before}" "${bc_dir}"
  _chain_lane_below "${bc_dir}" "${threshold}" || return 0
  log "[disk-lane] still below ${threshold}G; ${arch} skips local cache exports for its remaining stages"
  export CROSS_NO_LOCAL_CACHE_EXPORT=1
}

# One lane reclaims at a time, between that lane's stages and with the others still building.
_chain_lane_disk_guard() {
  local stage="$1" arch="$2" state="$3" threshold="${CROSS_DISK_GUARD_GB:-40}" lock
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  is_dry_run && return 0
  _disk_guard_positive_integer "${threshold}" || return 0
  _chain_lane_below "${bc_dir}" "${threshold}" || return 0
  exec {lock}>"${state}/disk.lock" || return 0
  flock "${lock}" || { exec {lock}>&-; return 0; }
  _chain_lane_reclaim "${stage}" "${arch}" "${state}" "${bc_dir}" "${threshold}" {lock}>&-
  exec {lock}>&-
  return 0
}

# Pins live in this subshell between stages, and reach the parent through the loop's harvest.
_chain_arch_lane() {
  local arch="$1" stage
  local -a stages=()
  mapfile -t stages < <(_chain_arch_pipeline_stages)
  for stage in "${stages[@]}"; do
    log "[arch-pipeline] arch=${arch} stage=${stage} start"
    cross_stage_run "${stage}" "${arch}" || { warn "[arch-pipeline] arch=${arch} stage=${stage} failed"; return 1; }
    : > "${_CHAIN_PIPELINE_STATE}/done.${stage}.${arch}"
    log "[arch-pipeline] arch=${arch} stage=${stage} done"
    _chain_lane_disk_guard "${stage}" "${arch}" "${_CHAIN_PIPELINE_STATE}"
  done
  : > "${_CHAIN_PIPELINE_STATE}/lane-done.${arch}"
}

# A stage is ok once every arch finished it; workers cannot touch the parent's status table.
_chain_arch_pipeline_report() {
  local state="$1" stage arch status
  local -a stages=() arches=()
  _chain_pipeline_lists
  for stage in "${stages[@]}"; do
    status=ok
    for arch in "${arches[@]}"; do
      [ -f "${state}/done.${stage}.${arch}" ] || status=failed
    done
    _chain_status_emit "${stage}" "${status}"
  done
  return 0
}

# Runs every enabled per-arch stage; the caller's guard runs after it, with nothing in flight.
chain_arch_pipeline_run() {
  local stage rc=0 saved="${PARALLEL_ARCHS:-0}"
  local -a stages=() arches=()
  _chain_pipeline_lists
  _CHAIN_PIPELINE_STATE="$(mktemp -d "${TMPDIR:-/tmp}/cross-arch-pipeline.XXXXXX")" || return 1
  for stage in "${stages[@]}"; do _chain_status_emit "${stage}" "running"; done
  log "[arch-pipeline] ${#arches[@]} arch(es) through ${stages[*]}, ${MAX_PARALLEL_ARCHS} at a time; each arch's next stage starts when its previous one is pushed"
  PARALLEL_ARCHS=1
  run_parallel_arch_loop _chain_arch_lane "$(arch_loop_flag_prefix cross-loop-flags)" "${MAX_PARALLEL_ARCHS}" "${arches[@]}" || rc=1
  PARALLEL_ARCHS="${saved}"
  _chain_arch_pipeline_report "${_CHAIN_PIPELINE_STATE}"
  rm -rf "${_CHAIN_PIPELINE_STATE}"
  _CHAIN_PIPELINE_STATE=""
  return "${rc}"
}

# True when the pipeline owns this stage, having run all of its stages at the first of them.
chain_arch_pipeline_takes() {
  chain_arch_pipeline_on || return 1
  cross_stage_is_per_arch "$1" || return 1
  [ "${_CHAIN_PIPELINE_RAN:-0}" -eq 0 ] || return 0
  _CHAIN_PIPELINE_RAN=1
  chain_arch_pipeline_run || err "the arch pipeline failed for one or more arches; every stage it reached is pushed, so re-run with --from-stage"
  # Nothing is in flight from here, so this guard may take the image store.
  _chain_stage_disk_guard "$(_chain_arch_pipeline_stages | tail -1)"
  return 0
}
