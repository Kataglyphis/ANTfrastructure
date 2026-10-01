#!/usr/bin/env bash
# Disk-guard helpers for build-cross-chain.sh, split out because that script runs main on load and cannot be sourced.
[ -n "${_DISK_GUARD_SH_LOADED:-}" ] && return 0
_DISK_GUARD_SH_LOADED=1

# Free GiB on <path>'s own fs (not its parent's, which differs at a mountpoint); empty means unknown.
_disk_guard_free_gb() {
  local probe="${1:-}"
  [ -n "${probe}" ] || probe="/"
  while [ ! -e "${probe}" ]; do
    case "${probe}" in
      */*) probe="${probe%/*}"; [ -n "${probe}" ] || probe="/" ;;
      *)   probe="."; break ;;
    esac
  done
  # `|| true`: callers run under pipefail, and "cannot determine free space" must not abort them.
  df -BG --output=avail "${probe}" 2>/dev/null | tail -1 | tr -dc '0-9' || true
}

# Oldest slug dir under $1 not in the protected CSV $2; empty output means nothing prunable.
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

# Tags of enabled stages after $1 ($2=1 adds $1's own: the next stage's parent); needs lib-orchestrator.sh's stage graph.
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
  # The last `[ -n ]` may be false; returning its status would trip errexit in callers.
  return 0
}

# Cache slugs of those stages, mapped exactly as cross-stage-build.sh does (/:@ -> _).
_disk_guard_protected_slugs() {
  local tag out=""
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    out+="${out:+,}$(printf '%s' "${tag}" | tr '/:@' '___')"
  done < <(_disk_guard_stage_tags "$1" 0)
  printf '%s' "${out}"
}

# Cache-export trim: only that host dir, never the buildkit store. docs/build-cache-tiers.md#31-preflight-trim-d4-and-the-salvage-disk-gate-d5

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

# Always returns 0 and sets _DISK_GUARD_TRIM_FREED_BYTES/_REMOVED, so call it directly, not in $(...).
_DISK_GUARD_TRIM_FREED_BYTES=0
_DISK_GUARD_TRIM_REMOVED=0
_disk_guard_trim_cache_export() {
  local bc_dir="${1:-}" target_gb="${2:-}" protected="${3:-}" budget_bytes="${4:-}"
  # Keep the newest N: when the deficit exceeds the whole dir, the budget alone would wipe it.
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

# In-stage sampling and reclaim records. See docs/build-cache-tiers.md#32-in-stage-disk-watchdog-and-the-runtime-lane-gate-b2

# warn() when the caller has logging.sh, plain stderr otherwise (unit tests).
_disk_guard_warn() {
  if declare -F warn >/dev/null 2>&1; then warn "$@"; else printf '[WARN] %s\n' "$*" >&2; fi
}

# Buildkit-store fallback. See docs/build-cache-tiers.md#321-the-buildkit-store-fallback-disk1
_DISK_GUARD_BUILDKIT_FREED_GB=0
_DISK_GUARD_BUILDKIT_PRUNES=0

# Resets the once-per-episode prune credit; a gate calls it first or finds the credit spent by an earlier gate.
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

# The store as JSON, exact bytes (du's text rounds); "$@" are du filters. Empty when the store is unreachable.
_disk_guard_du_json() {
  _disk_guard_buildctl du "$@" --format '{{json .}}' 2>/dev/null || true
}

# MB of records a type==regular prune never frees; --keep-storage counts them (it bounds the WHOLE store). Empty when unknown.
_disk_guard_unprunable_mb() {
  _disk_guard_du_json \
    | jq -r '[.[] | select((.shared | not) and ((.recordType // "") as $t | $t != "" and $t != "regular")) | .size]
             | (add // 0) / 1000000 | ceil' 2>/dev/null || true
}

# --keep-storage (MB) that retains <keep_gb> of layer cache ON TOP of the unprunable records; without them a 100G keep empties the layer cache.
_disk_guard_regular_keep_mb() {
  local fixed
  fixed="$(_disk_guard_unprunable_mb)"
  case "${fixed}" in ''|*[!0-9]*) fixed=0 ;; esac
  printf '%s' "$(( ${1:-0} * 1000 + fixed ))"
}

# One "<cache id> <kept record> <stale record> <bytes> <in use>" line per surplus record. BuildKit reuses the lowest record id it can lock and makes a new one only while that is locked, so the rest are dead weight.
_disk_guard_cachemount_duplicates() {
  _disk_guard_du_json --filter type==exec.cachemount \
    | jq -r 'map(. + {cid: ((.description | capture("with id \"(?<i>[^\"]*)\"") | .i)
                            // (.description | capture("^cached mount (?<i>[^ ]+)") | .i) // "?")})
             | group_by(.cid) | map(select(length > 1) | sort_by(.id)) | .[]
             | .[0] as $k | .[1:][] | [$k.cid, $k.id, .id, .size, (.inUse // false)] | @tsv' 2>/dev/null || true
}

# Prints free GB and succeeds only when <path> is below <target_gb>; bad input or unknown df means "do nothing".
_disk_guard_lever_needed() {
  local before
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  before="$(_disk_guard_free_gb "${1:-}")"
  [ -n "${before}" ] || return 1
  [ "${before}" -lt "$2" ] || return 1
  printf '%s' "${before}"
}

# Knob, once-per-episode latch and tool checks for both levers; every refusal is logged, never silent.
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
    _disk_guard_buildctl prune --filter type==regular --keep-storage "$(_disk_guard_regular_keep_mb "${keep}")" >/dev/null 2>&1
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

# Image-store lever: removing images is only safe with no stage in flight. docs/build-cache-tiers.md#322-the-image-store-lever-disk3
_DISK_GUARD_IMAGE_FREED_GB=0
_DISK_GUARD_IMAGE_REMOVED=0
_DISK_GUARD_IMAGE_PRUNES=0

_disk_guard_nerdctl() { nerdctl "$@"; }

# This chain's cross-* stage tags, newest first (CreatedAt sorts lexically), minus protected ones.
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

# May the image lever run? Every refusal names itself.
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

# Dangling images first, then unneeded stage tags; never a system-wide prune, which would drop the cachemounts.
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

  # Measure free space per removal: shared layers make nominal image size meaningless. Hard-capped against spins.
  local guard=0
  while [ "${step}" -lt "${target_gb}" ] && [ "${guard}" -lt "${_DISK_GUARD_IMAGE_MAX_REMOVALS:-50}" ]; do
    guard=$(( guard + 1 ))
    tag="$(_disk_guard_image_candidates "${protected}" | head -1)"
    [ -n "${tag}" ] || break
    # Protect every attempted tag: one that survives its rmi would otherwise head the list forever.
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

# One greppable line per reclaim, including one that freed nothing: <where> <free_gb_before> <bc_dir>.
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

# Names what the operator can still reclaim by hand, so giving up does not read as an environment limit.
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

# One sample, reclaiming below <threshold_gb>; always returns 0 since a sampler must never abort a build.
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
  # in_flight=1: this sampler runs during a stage, when the image lever must refuse.
  _disk_guard_image_store_fallback "${bc_dir}" "${threshold}" "" 1
  _disk_guard_reclaim_record "in-stage" "${free_gb}" "${bc_dir}"
  return 0
}

# Backgrounded sampler; runs until killed or its owner dies (_DISK_GUARD_WATCH_MAX_ITERS bounds it in tests).
_disk_guard_watch_loop() {
  local bc_dir="${1:-}" threshold="${2:-}" interval="${3:-120}"
  local protected="${4:-}" keep_n="${5:-3}"
  # Die with the owner: a parent killed without running its traps would leave this trimming forever.
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

# Runtime-lane free-GB need, scaled by concurrency not arch count: arches run sequentially unless parallel=1.
_disk_guard_runtime_lane_need_gb() {
  local per_arch="${1:-120}" n_arch="${2:-1}" parallel="${3:-0}" conc=1
  case "${per_arch}" in ''|*[!0-9]*) per_arch=120 ;; esac
  case "${n_arch}" in ''|*[!0-9]*) n_arch=1 ;; esac
  [ "${n_arch}" -ge 1 ] || n_arch=1
  [ "${parallel}" = "1" ] && conc="${n_arch}"
  printf '%s' $(( per_arch * conc ))
}
