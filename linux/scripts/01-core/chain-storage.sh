#!/usr/bin/env bash
# Host storage policies use the orchestrator's stage selection and logging functions.

_chain_recover_disk_pressure() {
  local bc_dir="$1" threshold="$2" completed_stage="$3"
      if [ "${free_gb}" -lt "${threshold}" ]; then
        _disk_guard_buildkit_fallback "${bc_dir}" "${threshold}"
        free_gb="$(_disk_guard_free_gb "${bc_dir}")"
      fi
      # The image store is safe only between stages. docs/build-cache-tiers.md#322-the-image-store-lever-disk3
      if [ -z "${free_gb}" ] || [ "${free_gb}" -lt "${threshold}" ]; then
        _disk_guard_image_store_fallback "${bc_dir}" "${threshold}" \
          "$(_disk_guard_stage_tags "${completed_stage}" 1)" 0
        free_gb="$(_disk_guard_free_gb "${bc_dir}")"
      fi
      if [ -z "${free_gb}" ] || [ "${free_gb}" -lt "${threshold}" ]; then
        log "[disk-guard] still ${free_gb:-?}G free after pruning — skipping local cache exports for remaining stages (CROSS_NO_LOCAL_CACHE_EXPORT=1)"
        export CROSS_NO_LOCAL_CACHE_EXPORT=1
      else
        log "[disk-guard] after pruning: ${free_gb}G free"
      fi
}

_chain_preflight_trim_verdict() {
    if [ "${CROSS_PREFLIGHT_TRIM:-1}" != "0" ]; then
      _disk_guard_trim_cache_export "${bc_dir}" "${need_gb}" "" "" "${CROSS_TRIM_KEEP_SLUGS:-3}"
      trimmed="$(_disk_guard_free_gb "${bc_dir}")"
      [ -n "${trimmed}" ] && free_now="${trimmed}"
      bc_gb="$(du -sBG "${bc_dir}" 2>/dev/null | cut -f1 | tr -dc '0-9' || true)"
    fi
    if [ "${free_now}" -lt "${need_gb}" ]; then
      [ -n "${bc_gb}" ] && [ "${bc_gb}" -gt 40 ] && \
        log "  Reclaim ~${bc_gb}G: rm -rf ${bc_dir}/* (regenerable cross-run cache export)."
      log "  Also: buildctl prune ; nerdctl --namespace default system prune -f."
      err "Insufficient disk: ${free_now}G free, ~${need_gb}G recommended. Free space or set FORCE_LOW_DISK=1."
    else
      log "disk preflight OK after trim: ${free_now}G free (>= ~${need_gb}G for ${n_arch} arch from-stage ${FROM_STAGE})."
    fi
}

_chain_collect_archived_runs() {
  local line leaf
  while IFS= read -r line; do
    leaf="${line#* }"                                  # strip the mtime key
    [ -n "${leaf}" ] || continue
    [[ "${leaf}" =~ ^([0-9]{8}-[0-9]{6}(-[A-Za-z0-9]+)?|[0-9]{1,10})$ ]] || continue
    [ "${leaf}" = "${CROSS_RUN_ID:-}" ] && continue
    runs+=( "${leaf}" )
  done < <(find "${arch_dir}" -mindepth 1 -maxdepth 1 -type d ! -type l \
             -printf '%T@ %f\n' 2>/dev/null | sort -rn)
}

_chain_disk_preflight() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
  # The runtime stage also fills RUNTIME_CONTEXT_ROOT, so measure that filesystem too.
  local rt_root="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/opencode/runtime-build-contexts}"
  local rt_free_gb
  rt_free_gb="$(_disk_guard_free_gb "${rt_root}")"
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local free_gb n_arch per_arch need_gb bc_gb free_now trimmed
  # The cache dir's own filesystem: its parent is the wrong device when the cache is a mount.
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || free_gb="$(_disk_guard_free_gb /)"
  [ -n "${free_gb}" ] || return 0
  n_arch="$(arch_list_to_words "${TARGET_ARCHES}" | wc -w)"; [ "${n_arch}" -ge 1 ] || n_arch=1
  case "${FROM_STAGE}" in base|compiler|sdk|gpu) per_arch=60 ;; *) per_arch=40 ;; esac
  need_gb=$(( n_arch * per_arch )); [ "${need_gb}" -ge 60 ] || need_gb=60
  # || true: du fails on a never-built host, and the size is only advisory.
  bc_gb="$(du -sBG "${bc_dir}" 2>/dev/null | cut -f1 | tr -dc '0-9' || true)"

  # The runtime lane's transient cost: advisory here, _chain_runtime_lane_disk_gate enforces it.
  local rt_lane_gb combined
  if stage_enabled runtime; then
    rt_lane_gb="$(_chain_runtime_lane_need_gb)"
    combined=$(( need_gb + rt_lane_gb ))
    if [ "${free_gb}" -lt "${combined}" ]; then
      warn "DISK PREFLIGHT: this run also enters the runtime lane, which needs ~${rt_lane_gb}G more on top of the ~${need_gb}G of stage cost (~${combined}G total) — only ${free_gb}G is free. The lane-entry gate refuses there instead of ENOSPC-ing hours in (CROSS_RUNTIME_LANE_GB)."
    fi
  fi

  if [ "${free_gb}" -lt "${need_gb}" ]; then
    log "DISK PREFLIGHT: ${free_gb}G free < ~${need_gb}G recommended (${n_arch} arch(es), from-stage ${FROM_STAGE})."
    # Trim is the last resort, after FORCE_LOW_DISK and the dry-run guard (docs/build-cache-tiers.md).
    free_now="${free_gb}"
    if [ "${FORCE_LOW_DISK:-0}" = "1" ]; then
      log "  FORCE_LOW_DISK=1 — continuing on the warm cache, not trimming it (ENOSPC risk accepted)."
      return 0
    fi
    if is_dry_run; then
      log "  [DRY RUN] would trim regenerable cache exports in ${bc_dir}; nothing removed."
      return 0
    fi
    _chain_preflight_trim_verdict
  else
    log "disk preflight OK: ${free_gb}G free (>= ~${need_gb}G for ${n_arch} arch from-stage ${FROM_STAGE})."
  fi

  _chain_preflight_runtime_advisory
}

_chain_prune_archived_logs() {
  local keep="${CROSS_LOG_ARCHIVE_KEEP:-5}"
  case "${keep}" in
    ''|*[!0-9]*)
      warn "CROSS_LOG_ARCHIVE_KEEP='${keep}' is not a non-negative integer — archive retention skipped"
      return 0 ;;
  esac
  [ "${keep}" -gt 0 ] || return 0            # 0 = retention deliberately off
  local root="${LOG_DIR:-}"
  [ -n "${root}" ] || return 0               # `--log-dir ""` = opt out
  local arch_dir="${root}/archive"
  [ -d "${arch_dir}" ] && [ ! -L "${arch_dir}" ] || return 0

  # By mtime: timestamp and bare-PID run ids do not sort together lexically.
  local -a runs=()
  _chain_collect_archived_runs

  local total="${#runs[@]}"
  [ "${total}" -gt "${keep}" ] || return 0
  local i victim target removed=0
  for (( i = keep; i < total; i++ )); do              # index 0..keep-1 = kept
    victim="${runs[i]}"
    [ -n "${victim}" ] && [ -n "${arch_dir}" ] || continue
    target="${arch_dir}/${victim}"
    [ -d "${target}" ] && [ ! -L "${target}" ] || continue
    # The archiving mv above is recoverable; this rm is not, so preview it.
    if is_dry_run; then
      log "[DRY RUN] archive retention: would remove ${arch_dir}/${victim}"
      continue
    fi
    if rm -rf -- "${target}" 2>/dev/null; then
      removed=$(( removed + 1 ))
      log "archive retention: removed ${arch_dir}/${victim}"
    else
      warn "archive retention: could not remove ${arch_dir}/${victim}"
    fi
  done
  log "archive retention: ${removed} old run dir(s) removed, newest ${keep} kept (CROSS_LOG_ARCHIVE_KEEP=${keep})"
}


_chain_preflight_runtime_advisory() {
  # ~30G per arch of rootfs + OCI layout on the runtime-context filesystem.
  if [ -n "${rt_free_gb}" ] && [ "${rt_free_gb}" != "${free_gb}" ]; then
    local rt_need; rt_need=$(( n_arch * 30 ))
    if [ "${rt_free_gb}" -lt "${rt_need}" ]; then
      log "DISK PREFLIGHT (runtime contexts): ${rt_free_gb}G free on ${rt_root} < ~${rt_need}G for ${n_arch} arch(es) — the runtime stage may ENOSPC there."
    fi
  fi
}


_chain_cache_size_cap() {
  # Phase 2 — total-size cap: free-space pruning alone lets the dir grow across runs.
  local cap_gb="${CROSS_CACHE_MAX_GB:-250}"
  [ "${cap_gb}" -gt 0 ] 2>/dev/null || return 0
  local total_gb
  # || true: the dir is absent under NO_CACHE=1, a relocated cache dir, or a --only runtime resume.
  total_gb="$(du -s --block-size=1G "${bc_dir}" 2>/dev/null | cut -f1 || true)"
  [ -n "${total_gb}" ] && [ "${total_gb}" -gt "${cap_gb}" ] || return 0
  [ -n "${protected}" ] || protected="$(_disk_guard_protected_slugs "${completed_stage}")"
  log "[disk-guard] cache exports total ${total_gb}G > cap ${cap_gb}G — LRU-pruning ${bc_dir} down to the cap (protected: ${protected:-none})"
  _chain_evict_slugs "${bc_dir}" protected _chain_bc_total_gb _chain_num_above "${cap_gb}" total_gb
  [ -n "${total_gb}" ] || return 0
  log "[disk-guard] cache exports now ${total_gb}G (cap ${cap_gb}G)"
}
