#!/usr/bin/env bash
set -euo pipefail

# build-cross-chain.sh — full cross lane with digest-pinned stage handoff.
# Why: docs/linux-cross-builds.md#recommended-digest-pinned-orchestrator-build-cross-chainsh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

FINAL_IMAGE="${FINAL_IMAGE:-${IMAGE_REPO}:latest-cross}"
# Set by --final-image so _chain_resolve_final_image can tell "user chose this"
# from "still the default" — comparing against the default string cannot.
FINAL_IMAGE_SET=0
TARGET_ARCHES="$(resolve_arch_list)"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
# --log-dir "" opts out of per-stage logs; chain-status.json is unaffected.
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/build-logs}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DESCRIBE_CHAIN=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"
# PARALLEL_STAGES=csv limits which stages go parallel (default: all).
PARALLEL_STAGES="${PARALLEL_STAGES:-all}"

# True when ${1} may run its arches in parallel under --parallel-archs.
_stage_parallel_allowed() {
  [ "${PARALLEL_STAGES}" = "all" ] && return 0
  case ",${PARALLEL_STAGES}," in *",$1,"*) return 0 ;; esac
  return 1
}

# Digest reference pins captured during this run; declared by
# cross_stage_init_pins() from the stage graph, accessed via nameref.
cross_stage_init_pins

declare -A STAGE_INDEX=()
for i in "${!CROSS_STAGE_ORDER[@]}"; do
  STAGE_INDEX["${CROSS_STAGE_ORDER[$i]}"]="${i}"
done

stage_index() {
  local name="$1"
  local idx="${STAGE_INDEX[${name}]:--1}"
  if [ "${idx}" -ge 0 ]; then
    printf '%s' "${idx}"
    return 0
  fi
  warn "Unknown stage: ${name}"
  return 1
}

stage_enabled() {
  local name="$1" idx
  idx="$(stage_index "${name}")" || exit 1
  [ "${idx}" -ge "${FROM_STAGE_IDX}" ] && [ "${idx}" -le "${TO_STAGE_IDX}" ]
}

# ── usage ──

usage() {
  cat <<'EOF'
Usage: build-cross-chain.sh [options]

Builds the additive cross lane end-to-end with a digest-pinned stage handoff so
a freshly built stage is always consumed by the next one (no stale-tag reuse):

  base -> compiler -> sdk -> media -> android -> runtime

The stage chain is defined in linux/scripts/01-core/stage-defs.sh.  Every cross
stage is built on linux/amd64 and pushed to the registry; the next stage's FROM
is pinned to the pushed manifest digest.  The final "runtime" stage delegates to
build-runtime-manifest.sh to build per-arch base/package/torch wrapper images on
the real target platform and publish the multi-arch manifest.

Options:
  --target-arches LIST     Comma-separated arch list (default: amd64,arm64,riscv64)
  --architectures LIST     Alias for --target-arches
  --cross-targets LIST     Compiler target list baked into the compiler image
                           (default: amd64,arm64,riscv64; must cover --target-arches)
  --image-repo REPO        Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --final-image REF        Final multi-arch manifest ref (default: REPO:latest-cross)
  --from-stage STAGE       First stage to run: base|compiler|sdk|media|android|runtime
  --to-stage STAGE         Last stage to run (inclusive). Same value set.
  --only STAGE             Shorthand for --from-stage STAGE --to-stage STAGE
  --vulkan-version VER     Vulkan SDK version for the sdk stage
  --log-dir DIR            Tee each stage build into DIR/<stage>[-<arch>].log
                           (default out/build-logs; the empty string disables
                           per-stage logs and their per-run truncate/archive).
                           The previous run's stage logs are moved to
                           DIR/archive/<run-id>/ at start; only the newest
                           CROSS_LOG_ARCHIVE_KEEP (default 5) of those run
                           directories are kept, 0 keeps all of them.
                           chain-status.json is NOT written here — it stays in
                           the repo root (CROSS_CHAIN_STATUS_FILE overrides).
  --verify-chain           Resolve all upstream digests and warn if downstream images are stale
  --no-verify-ancestry     Skip the stale-ancestor check that guards partial runs
                           (--from-stage after base). By default the chain refuses
                           to build on a parent that was re-pushed after the child
                           it would inherit. Env: CROSS_VERIFY_ANCESTRY=0
  --describe-chain          Print the full stage graph with tag names (no builds)
  --dry-run                 Print build commands without executing them
  --no-push                 Build every stage LOCALLY and skip all ghcr pushes.
                            Full chains (from base) are SAFE since 2026-08-30:
                            every stage built locally is exported as an OCI
                            layout and handed to the child via --build-context,
                            so no FROM resolves against the registry. A chain
                            resumed mid-way (--from-stage after base) is still
                            REFUSED — the parent prefix was not built this run.
                            Safe for --only/single-stage and dry runs.
                            Disable the handoff (reverting to the refusal):
                            CROSS_LOCAL_CONTEXT_HANDOFF=0. Override:
                            CROSS_NO_PUSH_FORCE=1 (accept the stale-parent risk).
  --parallel-archs          Build per-arch stages (sdk/media/android) in parallel
  --max-parallel-archs N    Max concurrent arch builds (default: 4)
                            Env PARALLEL_STAGES=all|csv (e.g. "sdk,android")
                            limits WHICH stages parallelize (default: all)
EOF
  orchestrator_usage_mirror_options
  cat <<'EOF'
  -h, --help               Show this help text

Notes:
  * When resuming mid-chain (e.g. --from-stage media), the required upstream
    digest is resolved from the parent stage's current registry tag.
  * Digest pinning requires pushing each cross stage; this is mandatory and
    matches the existing documented cross flow.
  * For single-stage rebuilds, use build-cross-stage.sh instead:
      bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
EOF
}

# ── runtime stage helpers ──

# Delegates to build-runtime-manifest.sh for per-arch wrapper images + manifest.
run_runtime_stage() {
  cross_stage_ensure_parent_available "runtime" "${TARGET_ARCHES}"

  local -a helper_args
  cross_stage_assemble_runtime_helper_args helper_args

  if is_dry_run; then
    log "[stage runtime] [DRY RUN] would run build-runtime-manifest.sh ${helper_args[*]}"
    return 0
  fi

  # B2: refuse a lane that cannot fit, before hours are spent on it. § 3.2
  # A refusal here is a stage FAILURE, not a silent stop: without this the
  # status file keeps claiming the runtime stage is still running.
  _chain_runtime_lane_disk_gate || { _chain_status_emit runtime failed; return 1; }

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  # C (2026-08-30): under --no-push the android image was exported to
  # <cross workdir>/android-artifacts/<arch>; hand that to the helper so its
  # package build copies from THIS image instead of the (stale) registry tag.
  local _art_root=""
  if [ "${CROSS_NO_PUSH:-0}" = "1" ] && [ -n "${CROSS_CONTEXT_WORKDIR:-}" ]; then
    _art_root="${CROSS_CONTEXT_WORKDIR}/android-artifacts"
    export ARTIFACT_CONTEXT_ROOT="${_art_root}"
    export ARTIFACT_CONTEXT_MODE="oci"
  else
    unset ARTIFACT_CONTEXT_ROOT 2>/dev/null || true
    unset ARTIFACT_CONTEXT_MODE 2>/dev/null || true
  fi
  # Sampler runs FOR the duration of the helper; stopped on both paths.
  local _rt_rc=0
  _chain_disk_watch_start runtime
  run env NERDCTL_BIN="${NERDCTL_BIN}" \
    bash "${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh" "${helper_args[@]}" || _rt_rc=$?
  _chain_disk_watch_stop
  return "${_rt_rc}"
}

# Avoids function-redefinition race in loops: bash definitions are global, so a
# redefinition inside the stage loop would race live workers.
_cross_per_arch_build() {
  local _arch="$1"
  cross_stage_run "${_CROSS_CURRENT_STAGE}" "${_arch}"
}

# ── main driver ──

_chain_extra_arg() {
  case "$1" in
    --cross-targets) CROSS_TARGETS="$2"; _OARG_SHIFT=2 ;;
    --final-image) FINAL_IMAGE="$2"; FINAL_IMAGE_SET=1; _OARG_SHIFT=2 ;;
    --from-stage) FROM_STAGE="$2"; _OARG_SHIFT=2 ;;
    --to-stage) TO_STAGE="$2"; _OARG_SHIFT=2 ;;
    --only) ONLY_STAGE="$2"; _OARG_SHIFT=2 ;;
    --log-dir) LOG_DIR="$2"; _OARG_SHIFT=2 ;;
    --verify-chain) VERIFY_CHAIN_ONLY=1; _OARG_SHIFT=1 ;;
    --describe-chain) DESCRIBE_CHAIN=1; _OARG_SHIFT=1 ;;
    --no-push) CROSS_NO_PUSH=1; export CROSS_NO_PUSH; _OARG_SHIFT=1
      # Parse-time inform + runtime guard decides: full chains are safe since
      # 2026-08-30 (local OCI-layout handoff); mid-chain runs are still refused.
      log "--no-push: full chains use the local OCI-layout stage handoff; mid-chain runs (--from-stage after base) are refused unless CROSS_NO_PUSH_FORCE=1." ;;
    --no-verify-ancestry) CROSS_VERIFY_ANCESTRY=0; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

_chain_parse_args() {
  ONLY_STAGE=""
  # --push is inert here (every cross stage is ALWAYS pushed; --no-push is the
  # real toggle) — warn instead of letting it sink silently.
  ORCHESTRATOR_UNSUPPORTED_FLAGS="--push"
  run_orchestrator_arg_loop usage _chain_extra_arg \
    TARGET_ARCHES USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
    FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO VULKAN_VERSION _chain_push_enabled \
    "$@"

  if [ -n "${ONLY_STAGE}" ]; then
    FROM_STAGE="${ONLY_STAGE}"
    TO_STAGE="${ONLY_STAGE}"
  fi
}

_chain_resolve_final_image() {
  cd "${REPO_ROOT}"
  # The default was computed from the default IMAGE_REPO, so --image-repo must
  # recompute it; an explicit --final-image always wins.
  if [ "${FINAL_IMAGE_SET}" -eq 0 ]; then
    FINAL_IMAGE="${IMAGE_REPO}:latest-cross"
  fi
}

_chain_validate_stages() {
  FROM_STAGE_IDX="$(stage_index "${FROM_STAGE}")" || exit 1
  TO_STAGE_IDX="$(stage_index "${TO_STAGE}")" || exit 1
  if [ "${FROM_STAGE_IDX}" -gt "${TO_STAGE_IDX}" ]; then
    err "--from-stage (${FROM_STAGE}) is after --to-stage (${TO_STAGE})"
  fi

  log "Cross chain: arches=${TARGET_ARCHES} stages=${FROM_STAGE}..${TO_STAGE} repo=${IMAGE_REPO}"

  if [ "${DESCRIBE_CHAIN}" -eq 1 ]; then
    describe_cross_chain "${TARGET_ARCHES}"
    exit 0
  fi

  if [ "${VERIFY_CHAIN_ONLY}" -eq 1 ]; then
    # Exit non-zero on STALE: a verification that cannot fail is not a verification.
    if verify_cross_chain_staleness "${TARGET_ARCHES}"; then
      exit 0
    else
      exit 2
    fi
  fi
}

# Refuse to resume on a stale ancestor: digest pinning only makes a SINGLE run
# consistent (docs/linux-cross-builds.md, "stale-base propagation").
_chain_assert_ancestry() {
  if [ "${CROSS_VERIFY_ANCESTRY:-1}" != "1" ]; then
    log "ancestry verification disabled (CROSS_VERIFY_ANCESTRY=0)"
    return 0
  fi
  # Nothing to check against: local-only runs never consult the registry, and a
  # dry run builds nothing.
  if [ "${CROSS_NO_PUSH:-0}" = "1" ]; then
    return 0
  fi
  if is_dry_run; then
    return 0
  fi
  ancestry_assert_chain "${FROM_STAGE}" "${TARGET_ARCHES}" \
    || err "Stale ancestor — refusing to build on it (see the [ancestry] lines above). Restart from the oldest stage reported, or set CROSS_VERIFY_ANCESTRY=0 to accept it."
}

# --no-push multi-stage guard: BuildKit's OCI worker resolves FROM against the
# registry, not the local store. Since 2026-08-30 the chain carries its own
# OCI-layout handoff (cross-stage-build.sh: every stage built locally is
# exported and handed to the child as --build-context <tag>=oci-layout://<dir>,
# and android is additionally exported for the runtime lane), so a FULL chain
# (from base) is safe and allowed. A run resuming mid-chain (--from-stage after
# base) still refuses: the parent prefix was not built this run, so the FROM
# would resolve against the registry again. Escape hatch: CROSS_NO_PUSH_FORCE=1.
_chain_no_push_guard() {
  [ "${CROSS_NO_PUSH:-0}" = "1" ] || return 0
  is_dry_run && return 0
  if [ "${FROM_STAGE_IDX}" -lt "${TO_STAGE_IDX}" ]; then
    if cross_local_handoff_enabled && [ "${FROM_STAGE_IDX}" -eq 0 ]; then
      log "--no-push multi-stage: local OCI-layout stage handoff active — every parent is served from the image this run built (CROSS_LOCAL_CONTEXT_HANDOFF=0 reverts to the refusal)."
      return 0
    fi
    if [ "${CROSS_NO_PUSH_FORCE:-0}" = "1" ]; then
      warn "--no-push multi-stage: CROSS_NO_PUSH_FORCE=1 — downstream stages may build on the last PUSHED parent (stale-ancestor risk accepted)."
      return 0
    fi
    err "--no-push is unsafe for mid-chain runs on this host: BuildKit's OCI worker resolves FROM against the registry, and a run resumed after base has no locally-built parent to serve (two runs lost 2026-08-08). A full chain from base is allowed since 2026-08-30 (local OCI-layout handoff); use --only STAGE for single-stage validation, or set CROSS_NO_PUSH_FORCE=1 to accept the risk."
  fi
}

# chain-status.json: atomic tmp+mv at each stage start/ok/fail. Pinned to REPO
# ROOT, NOT LOG_DIR — a moved file would freeze the tracked copy stale-GREEN.
declare -A _CHAIN_STATUS=()
_chain_status_emit() {
  local stage="$1" status="$2"
  _CHAIN_STATUS["${stage}"]="${status}"
  local out="${CROSS_CHAIN_STATUS_FILE:-${REPO_ROOT:-.}/chain-status.json}" tmp
  # A bare filename has no "/" to strip, so ${out%/*} would expand to the
  # filename itself and the -d test would silently reject every write. Treat a
  # path with no directory component as "the current directory".
  local out_dir="${out%/*}"
  [ "${out_dir}" = "${out}" ] && out_dir="."
  [ -d "${out_dir}" ] || return 0
  tmp="$(mktemp "${out}.XXXXXX" 2>/dev/null)" || return 0
  {
    printf '{\n'
    printf '  "run_id": "%s",\n' "${CROSS_RUN_ID:-}"
    printf '  "arches": "%s",\n' "${TARGET_ARCHES:-}"
    printf '  "range": "%s..%s",\n' "${FROM_STAGE:-}" "${TO_STAGE:-}"
    printf '  "stages": {'
    local s sep="" pin_var pin_val
    for s in "${CROSS_STAGE_ORDER[@]}"; do
      [ -n "${_CHAIN_STATUS[$s]:-}" ] || continue
      pin_val=""
      pin_var="$(cross_stage_pin_varname "${s}" 2>/dev/null || true)"
      [ -n "${pin_var}" ] && pin_val="${!pin_var:-}"
      printf '%s\n    "%s": {"status": "%s", "pin": "%s"}' \
        "${sep}" "${s}" "${_CHAIN_STATUS[$s]}" "${pin_val}"
      sep=','
    done
    printf '\n  },\n'
    # B3: only present when a runtime failure recorded them, so a green run's
    # file stays byte-identical for existing consumers.
    if [ -n "${_CHAIN_ARCH_OUTCOMES:-}" ]; then
      printf '  "arch_outcomes": {%s},\n' "$(chain_status_kv_json "${_CHAIN_ARCH_OUTCOMES}")"
    fi
    if [ -n "${_CHAIN_GATES_NOT_RUN:-}" ]; then
      printf '  "gates_not_run": [%s],\n' "$(chain_status_list_json "${_CHAIN_GATES_NOT_RUN}")"
    fi
    printf '  "updated": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } >"${tmp}" 2>/dev/null || { rm -f "${tmp}"; return 0; }
  mv -f "${tmp}" "${out}" 2>/dev/null || rm -f "${tmp}"
}

_chain_run_build_loop() {
  cross_stage_validate_graph || err "Stage graph validation failed"

  local stage
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    stage_enabled "${stage}" || continue
    # Explicit `|| err` on every stage: set -e is unreliable here (the per-arch
    # path runs under run_parallel_arch_loop's `if !`) and a failure MUST abort.
    _chain_status_emit "${stage}" "running"
    case "${stage}" in
      runtime)
        run_runtime_stage \
          || { _chain_runtime_failure_report || true   # a diagnostic must never change the exit code
               _chain_status_emit "${stage}" "failed"
               err "runtime stage failed"; }
        ;;
      *)
        if cross_stage_is_per_arch "${stage}"; then
          _CROSS_CURRENT_STAGE="${stage}"
          # Demote to sequential when PARALLEL_STAGES excludes this stage; later stages decide independently.
          _par_saved="${PARALLEL_ARCHS:-0}"
          _stage_parallel_allowed "${stage}" || PARALLEL_ARCHS=0
          run_parallel_arch_loop _cross_per_arch_build "$(arch_loop_flag_prefix cross-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}") \
            || { _chain_status_emit "${stage}" "failed"; err "stage ${stage} failed for one or more arches"; }
          PARALLEL_ARCHS="${_par_saved}"
        else
          cross_stage_run "${stage}" \
            || { _chain_status_emit "${stage}" "failed"; err "stage ${stage} failed"; }
        fi
        ;;
    esac
    _chain_status_emit "${stage}" "ok"
    # Reclaim regenerable cache between stages if the host is running low, so the
    # next (heavier) stage doesn't ENOSPC. No-op above CROSS_DISK_GUARD_GB free.
    _chain_stage_disk_guard "${stage}"
  done
}

# Fail-fast disk preflight. FORCE_LOW_DISK=1 downgrades; DISK_PREFLIGHT=0 skips.
_chain_disk_preflight() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
  # The runtime stage also fills RUNTIME_CONTEXT_ROOT (tens of GB) — measure that
  # filesystem too when it differs, so both growth points are guarded.
  local rt_root="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/opencode/runtime-build-contexts}"
  local rt_free_gb
  rt_free_gb="$(_disk_guard_free_gb "${rt_root}")"
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local free_gb n_arch per_arch need_gb bc_gb free_now trimmed
  # Measure the cache dir's OWN filesystem (see _disk_guard_free_gb) — using the
  # parent dir silently reads the wrong device when the cache is its own mount.
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || free_gb="$(_disk_guard_free_gb /)"
  [ -n "${free_gb}" ] || return 0
  n_arch="$(arch_list_to_words "${TARGET_ARCHES}" | wc -w)"; [ "${n_arch}" -ge 1 ] || n_arch=1
  case "${FROM_STAGE}" in base|compiler|sdk) per_arch=60 ;; *) per_arch=40 ;; esac
  need_gb=$(( n_arch * per_arch )); [ "${need_gb}" -ge 60 ] || need_gb=60
  # `|| true`: `du` on a never-built host exits non-zero and pipefail + set -e
  # aborted the orchestrator here with no diagnostic. The size is advisory.
  bc_gb="$(du -sBG "${bc_dir}" 2>/dev/null | cut -f1 | tr -dc '0-9' || true)"

  # The sizing above does NOT cover the runtime lane's own transient cost.
  # Advisory here; _chain_runtime_lane_disk_gate enforces it. § 3.2
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
    # D4 trim: LAST RESORT only. It runs after FORCE_LOW_DISK and after the
    # dry-run guard, and keeps the newest slugs. docs/build-cache-tiers.md
    free_now="${free_gb}"
    if [ "${FORCE_LOW_DISK:-0}" = "1" ]; then
      log "  FORCE_LOW_DISK=1 — continuing on the warm cache, not trimming it (ENOSPC risk accepted)."
      return 0
    fi
    if is_dry_run; then
      log "  [DRY RUN] would trim regenerable cache exports in ${bc_dir}; nothing removed."
      return 0
    fi
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
  else
    log "disk preflight OK: ${free_gb}G free (>= ~${need_gb}G for ${n_arch} arch from-stage ${FROM_STAGE})."
  fi

  # Runtime-context filesystem, only when it differs from the cache dir's: ~30G
  # per arch of rootfs + OCI layout during the runtime stage.
  if [ -n "${rt_free_gb}" ] && [ "${rt_free_gb}" != "${free_gb}" ]; then
    local rt_need=$(( n_arch * 30 ))
    if [ "${rt_free_gb}" -lt "${rt_need}" ]; then
      log "DISK PREFLIGHT (runtime contexts): ${rt_free_gb}G free on ${rt_root} < ~${rt_need}G for ${n_arch} arch(es) — the runtime stage may ENOSPC there."
    fi
  fi
}

# Between-stage disk safety valve: the local --cache-to export is the ONLY
# regenerable mid-run space. Policy and knobs: docs/build-cache-tiers.md.

# Pure helpers (_disk_guard_pick_victim, _disk_guard_protected_slugs) live in
# 01-core/disk-guard.sh so linux/scripts/tests can unit-test them.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/disk-guard.sh"

# Run-id / pidfile / child-reaping primitives shared with stop-cross-chain.sh.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/chain-lifecycle.sh"

# Is the runtime lane the very next ENABLED stage? Its entry gate refuses below
# ~120G, which the between-stage guard's 40G default cannot deliver in time.
_chain_runtime_lane_is_next() {
  local completed="${1:-}" s seen=0

  [ -n "${completed}" ] || return 1
  stage_enabled runtime || return 1
  for s in "${CROSS_STAGE_ORDER[@]}"; do
    if [ "${seen}" -eq 0 ]; then
      [ "${s}" = "${completed}" ] && seen=1
      continue
    fi
    stage_enabled "${s}" || continue
    [ "${s}" = "runtime" ] && return 0
    return 1
  done
  return 1
}

_chain_stage_disk_guard() {
  local completed_stage="${1:-}"
  local threshold="${CROSS_DISK_GUARD_GB:-40}"
  local _rt_need
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local protected="" victim free_gb

  # Aim at what comes NEXT, not at a fixed floor: reclaiming at 40G before a lane
  # that refuses below ~120G arrives far too late. It cost six manual prunes on
  # 2026-09-02. docs/failure-modes.md#the-disk-guard-aims-at-the-wrong-number
  if _chain_runtime_lane_is_next "${completed_stage}"; then
    _rt_need="$(_chain_runtime_lane_need_gb 2>/dev/null || true)"
    case "${_rt_need}" in
      ''|*[!0-9]*) : ;;
      *) [ "${_rt_need}" -gt "${threshold}" ] && threshold="${_rt_need}" ;;
    esac
  fi

  if [ "${threshold}" -gt 0 ] 2>/dev/null; then
    free_gb="$(_disk_guard_free_gb "${bc_dir}")"
    if [ -n "${free_gb}" ] && [ "${free_gb}" -lt "${threshold}" ]; then
      protected="$(_disk_guard_protected_slugs "${completed_stage}")"
      log "[disk-guard] ${free_gb}G free < ${threshold}G after stage ${completed_stage:-?} — LRU-pruning cache exports in ${bc_dir} (protected: ${protected:-none})"
      _disk_guard_reclaim_begin
      while [ "${free_gb}" -lt "${threshold}" ]; do
        victim="$(_disk_guard_pick_victim "${bc_dir}" "${protected}")"
        [ -n "${victim}" ] || break
        log "[disk-guard]   pruning slug ${victim} ($(du -sh "${bc_dir}/${victim}" 2>/dev/null | cut -f1 || echo '?'))"
        rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
        # An undeletable slug stays the LRU pick forever: without this the loop
        # spins for the rest of the run. Protect it and move on.
        if [ -e "${bc_dir}/${victim}" ]; then
          warn "[disk-guard]   could not remove ${victim}; skipping it"
          protected="${protected},${victim}"
        fi
        free_gb="$(_disk_guard_free_gb "${bc_dir}")"
        [ -n "${free_gb}" ] || return 0
      done
      if [ "${free_gb}" -lt "${threshold}" ]; then
        _disk_guard_buildkit_fallback "${bc_dir}" "${threshold}"
        free_gb="$(_disk_guard_free_gb "${bc_dir}")"
      fi
      if [ -z "${free_gb}" ] || [ "${free_gb}" -lt "${threshold}" ]; then
        log "[disk-guard] still ${free_gb:-?}G free after pruning — skipping local cache exports for remaining stages (CROSS_NO_LOCAL_CACHE_EXPORT=1)"
        export CROSS_NO_LOCAL_CACHE_EXPORT=1
      else
        log "[disk-guard] after pruning: ${free_gb}G free"
      fi
    fi
  fi

  # Phase 2 — total-size cap: free-space pruning alone lets the dir grow across runs.
  local cap_gb="${CROSS_CACHE_MAX_GB:-250}"
  [ "${cap_gb}" -gt 0 ] 2>/dev/null || return 0
  local total_gb
  # || true: du on a missing cache dir exits non-zero under pipefail + set -e.
  # The dir can be absent: NO_CACHE=1, a relocated BUILDKIT_CACHE_DIR, or a --only
  # runtime resume.
  total_gb="$(du -s --block-size=1G "${bc_dir}" 2>/dev/null | cut -f1 || true)"
  [ -n "${total_gb}" ] && [ "${total_gb}" -gt "${cap_gb}" ] || return 0
  [ -n "${protected}" ] || protected="$(_disk_guard_protected_slugs "${completed_stage}")"
  log "[disk-guard] cache exports total ${total_gb}G > cap ${cap_gb}G — LRU-pruning ${bc_dir} down to the cap (protected: ${protected:-none})"
  while [ "${total_gb}" -gt "${cap_gb}" ]; do
    victim="$(_disk_guard_pick_victim "${bc_dir}" "${protected}")"
    [ -n "${victim}" ] || break
    log "[disk-guard]   pruning slug ${victim} ($(du -sh "${bc_dir}/${victim}" 2>/dev/null | cut -f1 || echo '?'))"
    rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
    # An undeletable slug stays the LRU pick forever: without this the loop
    # spins for the rest of the run. Protect it and move on.
    if [ -e "${bc_dir}/${victim}" ]; then
      warn "[disk-guard]   could not remove ${victim}; skipping it"
      protected="${protected},${victim}"
    fi
    total_gb="$(du -s --block-size=1G "${bc_dir}" 2>/dev/null | cut -f1 || true)"
    [ -n "${total_gb}" ] || return 0
  done
  log "[disk-guard] cache exports now ${total_gb}G (cap ${cap_gb}G)"
}

# ── B2: guards that work INSIDE a stage ──────────────────────────────────────
# The runtime lane is ONE stage, so _chain_stage_disk_guard cannot fire in it.
# Evidence, numbers and knobs: docs/build-cache-tiers.md § 3.2.

_CHAIN_DISK_WATCH_PID=""

# Free-GB the runtime lane needs right now (arch count x concurrency).
_chain_runtime_lane_need_gb() {
  # The runtime lane builds arches SERIALLY (runtime_build_chain loops), so
  # --parallel-archs must not scale this. Peak is ONE wrapper at a time.
  local n_arch
  n_arch="$(arch_list_to_words "${TARGET_ARCHES}" | wc -w)"
  _disk_guard_runtime_lane_need_gb "${CROSS_RUNTIME_LANE_GB:-120}" "${n_arch}" 0
}

# Lane-entry gate: refuse the runtime lane when it cannot possibly fit, instead
# of finding out hours in. FORCE_LOW_DISK / --dry-run precede the trim.
_chain_runtime_lane_disk_gate() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
  case "${CROSS_RUNTIME_LANE_GB:-120}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${CROSS_RUNTIME_LANE_GB:-120}" -gt 0 ] || return 0
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local need free_gb protected
  need="$(_chain_runtime_lane_need_gb)"
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0
  if [ "${free_gb}" -ge "${need}" ]; then
    log "[disk-guard] runtime lane: ${free_gb}G free (>= ~${need}G needed)"
    return 0
  fi
  if [ "${FORCE_LOW_DISK:-0}" = "1" ]; then
    warn "[disk-guard] runtime lane: ${free_gb}G free, ~${need}G needed — FORCE_LOW_DISK=1, continuing on the warm cache without trimming it."
    return 0
  fi
  if is_dry_run; then
    log "[disk-guard] [DRY RUN] runtime lane would reclaim in ${bc_dir}; nothing removed."
    return 0
  fi
  log "[disk-guard] runtime lane needs ~${need}G free but only ${free_gb}G is left — reclaiming before the wrapper builds start."
  protected="$(_disk_guard_protected_slugs '')"
  _disk_guard_reclaim_begin
  _disk_guard_trim_cache_export "${bc_dir}" "${need}" "${protected}" "" "${CROSS_TRIM_KEEP_SLUGS:-3}"
  _disk_guard_buildkit_fallback "${bc_dir}" "${need}"
  _disk_guard_reclaim_record "runtime-lane-entry" "${free_gb}" "${bc_dir}"
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0
  [ "${free_gb}" -lt "${need}" ] || return 0
  err "runtime lane refused: ${free_gb}G free, ~${need}G needed (${CROSS_RUNTIME_LANE_GB:-120}G per concurrent wrapper build). The 2026-09-01 run entered this lane with 88G and died 28 minutes later with 'no image was built'. Free space, then re-run with --from-stage runtime; or set FORCE_LOW_DISK=1 / CROSS_RUNTIME_LANE_GB=0 to accept the risk."
}

# Background disk sampler for the duration of ONE stage. Reuses the between-stage
# threshold and the keep-floor trim, then the filtered buildkit reclaim when that
# is not enough (DISK1) -- filtered to type==regular, so the cachemounts survive.
_chain_disk_watch_start() {
  _CHAIN_DISK_WATCH_PID=""
  [ "${CROSS_DISK_WATCH:-1}" = "1" ] || return 0
  is_dry_run && return 0
  local threshold="${CROSS_DISK_GUARD_GB:-40}" secs="${CROSS_DISK_WATCH_SECS:-120}"
  case "${threshold}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${threshold}" -gt 0 ] || return 0
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local protected
  protected="$(_disk_guard_protected_slugs '')"
  # Pass $$ explicitly: inside the backgrounded subshell $PPID is OUR parent, not
  # us, so the loop's die-with-owner check would watch the wrong process.
  _disk_guard_watch_loop "${bc_dir}" "${threshold}" "${secs}" "${protected}" \
    "${CROSS_TRIM_KEEP_SLUGS:-3}" "$$" &
  _CHAIN_DISK_WATCH_PID=$!
  log "[disk-watch] sampling ${bc_dir} every ${secs}s during the ${1:-current} stage (threshold ${threshold}G; CROSS_DISK_WATCH=0 disables)"
}

_chain_disk_watch_stop() {
  [ -n "${_CHAIN_DISK_WATCH_PID}" ] || return 0
  kill "${_CHAIN_DISK_WATCH_PID}" 2>/dev/null || true
  wait "${_CHAIN_DISK_WATCH_PID}" 2>/dev/null || true
  _CHAIN_DISK_WATCH_PID=""
}

# ── B3: name what a runtime failure left unverified ──────────────────────────
# Every gate below sits AFTER build-runtime-manifest.sh's per-arch wrapper loop,
# so one failed arch skips them all. docs/build-cache-tiers.md § 3.3.
_CHAIN_RUNTIME_GATES="wrapper-content-gate,verify-shipped-wrapper,runtime-image-smoke,assert_pinned_versions,manifest-coherence,manifest-completeness,manifest-freshness"
_CHAIN_ARCH_OUTCOMES=""
_CHAIN_GATES_NOT_RUN=""

# built-this-run | stale | missing — from the wrapper tag's own run-id stamp,
# the same provenance the manifest coherence gate reads.
_chain_runtime_arch_state() {
  local arch="$1" rid
  rid="$(ancestry_recorded_run_id "${FINAL_IMAGE}-${arch}" 2>/dev/null || true)"
  if [ -z "${rid}" ]; then printf 'missing'
  elif [ "${rid}" = "${CROSS_RUN_ID:-}" ]; then printf 'built-this-run'
  else printf 'stale'; fi
}

# Sets _CHAIN_ARCH_OUTCOMES / _CHAIN_GATES_NOT_RUN — call it directly, a $(...)
# subshell would discard both.
_chain_runtime_failure_report() {
  local arch state outcomes="" absent=""
  for arch in $(arch_list_to_words "${TARGET_ARCHES}"); do
    state="$(_chain_runtime_arch_state "${arch}")"
    outcomes="${outcomes:+${outcomes},}${arch}=${state}"
    [ "${state}" = "built-this-run" ] || absent="${absent:+${absent} }${arch}"
  done
  _CHAIN_ARCH_OUTCOMES="${outcomes}"
  warn "[runtime-failure] per-arch wrapper outcome: ${outcomes}"
  if [ -n "${absent}" ]; then
    _CHAIN_GATES_NOT_RUN="${_CHAIN_RUNTIME_GATES}"
    warn "[runtime-failure] the wrapper loop produced no image of THIS run for: ${absent}"
    warn "[runtime-failure] every gate downstream of that loop was therefore SKIPPED for ALL arches: ${_CHAIN_RUNTIME_GATES}"
    warn "[runtime-failure] NOTHING in this run is verified — a --manifest-only repair would index UNCHECKED wrappers. chain-status.json records this."
  else
    _CHAIN_GATES_NOT_RUN=""
    warn "[runtime-failure] every arch carries this run's id, so the failure is AT or AFTER one of: ${_CHAIN_RUNTIME_GATES} — find which one above."
  fi
}

_chain_start_resource_monitor() { start_resource_monitor cross; }

# ── lifecycle: pidfile + signal-driven child reaping ──
#
# EXIT/TERM/INT/HUP only — never a RETURN trap (re-arms on caller's return under
# set -u). Bash defers a trap until a foreground pipeline finishes, so a bare
# TERM during a non-per-arch stage is queued — stop-cross-chain.sh reaps the
# child subtree directly (docs/cross-build-verification.md).
_CHAIN_PIDFILE=""
_CHAIN_SIGNAL_HANDLED=0

# PID of a live sibling chain, or empty. Reads the pidfile directly: this is
# needed BEFORE _chain_write_pidfile runs.
_chain_live_sibling_pid() {
  local pf other
  pf="$(cross_chain_pidfile_path)"
  [ -f "${pf}" ] || return 0
  other="$(cat "${pf}" 2>/dev/null || true)"
  [ -n "${other}" ] && [ "${other}" != "$$" ] && kill -0 "${other}" 2>/dev/null || return 0
  printf '%s' "${other}"
}

_chain_write_pidfile() {
  _CHAIN_PIDFILE="$(cross_chain_pidfile_path)"
  # A live SIBLING chain already owns this pidfile: warn (do not clobber its
  # ownership — the deliberate path to stop it is stop-cross-chain.sh).
  if [ -f "${_CHAIN_PIDFILE}" ]; then
    local other; other="$(cat "${_CHAIN_PIDFILE}" 2>/dev/null || true)"
    if [ -n "${other}" ] && [ "${other}" != "$$" ] && kill -0 "${other}" 2>/dev/null; then
      warn "another cross chain is running (pid ${other}); leaving ${_CHAIN_PIDFILE} pointing at IT so stop-cross-chain.sh still reaches it. This run continues WITHOUT a pidfile and cannot be stopped that way."
      _CHAIN_PIDFILE=""
      return 0
    fi
  fi
  printf '%s\n' "$$" > "${_CHAIN_PIDFILE}" 2>/dev/null \
    || { warn "could not write pidfile ${_CHAIN_PIDFILE}"; _CHAIN_PIDFILE=""; }
}

_chain_remove_pidfile() {
  [ -n "${_CHAIN_PIDFILE}" ] || return 0
  # Only remove a pidfile we own (contains OUR pid) — never a sibling's.
  if [ "$(cat "${_CHAIN_PIDFILE}" 2>/dev/null || true)" = "$$" ]; then
    rm -f "${_CHAIN_PIDFILE}" 2>/dev/null || true
  fi
}

# EXIT fires on normal completion AND after the signal handler. Pidfile cleanup
# ONLY: reaping here would kill the resource-monitor before it wrote its summary.
# The cross stage-context tree (--no-push OCI handoff) can be reclaimed here —
# nothing consumes it after the chain ends, and the age-sweep is belt-and-braces.
_chain_on_exit() {
  _chain_remove_pidfile
  if declare -F cross_cleanup_local_context_workdir >/dev/null 2>&1; then
    cross_cleanup_local_context_workdir
  fi
}

_chain_on_signal() {
  local sig="$1"
  # Idempotent: a second signal mid-teardown must not re-run the kill sweep.
  [ "${_CHAIN_SIGNAL_HANDLED}" -eq 1 ] && return 0
  _CHAIN_SIGNAL_HANDLED=1
  warn "received SIG${sig} — terminating child build processes (nerdctl/buildctl) before exit"
  chain_terminate_descendants TERM "$$"
  # Brief grace for a clean TERM, then KILL any straggler that ignored it.
  local waited=0
  while [ "${waited}" -lt 10 ]; do
    pgrep -P "$$" >/dev/null 2>&1 || break
    sleep 1
    waited=$((waited + 1))
  done
  chain_terminate_descendants KILL "$$"
  _chain_remove_pidfile
  # Exit 128+signum so the caller sees a signalled termination, not a bare 1.
  trap - "${sig}" EXIT
  local num=15
  case "${sig}" in INT) num=2 ;; HUP) num=1 ;; TERM) num=15 ;; esac
  exit $((128 + num))
}

_chain_install_lifecycle_traps() {
  trap '_chain_on_signal TERM' TERM
  trap '_chain_on_signal INT' INT
  trap '_chain_on_signal HUP' HUP
  trap '_chain_on_exit' EXIT
}

# Create LOG_DIR and prove it writable once, up front: the lazy mkdir inside a
# command substitution under set -e would take the whole orchestrator down.
_chain_prepare_log_dir() {
  [ -n "${LOG_DIR:-}" ] || return 0          # `--log-dir ""` = opt out
  if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [ ! -w "${LOG_DIR}" ]; then
    warn "log dir ${LOG_DIR} is not writable — per-stage logs and their per-run archiving are disabled; the resource-monitor CSV falls back to ${REPO_ROOT}"
    LOG_DIR=""
    return 0
  fi
  log "per-stage build logs -> ${LOG_DIR}/<stage>[-<arch>].log (--log-dir '' disables)"
}

# Eager per-run log archiving: per-stage logs are truncated lazily, so a watcher
# could read the previous run's log as current.
_chain_archive_prev_logs() {
  [ -n "${LOG_DIR:-}" ] && [ -d "${LOG_DIR}" ] || return 0
  local _sib
  _sib="$(_chain_live_sibling_pid)"
  if [ -n "${_sib}" ]; then
    warn "another cross chain is running (pid ${_sib}); NOT archiving logs -- its stage logs are live and mv would redirect its open writers"
    return 0
  fi
  shopt -s nullglob
  local markers=( "${LOG_DIR}"/*.log.run )
  shopt -u nullglob
  # Marker-scoped, NOT every *.log: LOG_DIR also holds the operator's own live
  # nohup/tee transcript, and mv-ing a file an open tee holds redirects it.
  [ "${#markers[@]}" -gt 0 ] || return 0
  local prev="" m
  for m in "${markers[@]}"; do
    prev="$(cat "${m}" 2>/dev/null || true)"
    [ -n "${prev}" ] && break
  done
  [ -n "${prev}" ] || prev="$(date -u +%Y%m%d-%H%M%S)"
  # Defensive: never archive our own current run's freshly-created logs.
  [ "${prev}" = "${CROSS_RUN_ID:-}" ] && return 0
  local dest="${LOG_DIR}/archive/${prev}"
  mkdir -p "${dest}" 2>/dev/null || return 0
  local f
  for m in "${markers[@]}"; do
    f="${m%.run}"
    if [ -e "${f}" ]; then mv -f "${f}" "${dest}/" 2>/dev/null || true; fi
    mv -f "${m}" "${dest}/" 2>/dev/null || true
  done
  log "archived previous run logs -> ${dest}"
}

# Bounded archive retention: the leaf must match a run-id shape — that keeps the
# composed path inside archive/, so do not loosen it.
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

  # Newest first by MTIME, not name: the two run-id shapes (timestamp and bare
  # PID) do not interleave lexically, which sorts the oldest dir to "newest".
  local -a runs=()
  local line leaf
  while IFS= read -r line; do
    leaf="${line#* }"                                  # strip the mtime key
    [ -n "${leaf}" ] || continue
    [[ "${leaf}" =~ ^([0-9]{8}-[0-9]{6}(-[A-Za-z0-9]+)?|[0-9]{1,10})$ ]] || continue
    [ "${leaf}" = "${CROSS_RUN_ID:-}" ] && continue
    runs+=( "${leaf}" )
  done < <(find "${arch_dir}" -mindepth 1 -maxdepth 1 -type d ! -type l \
             -printf '%T@ %f\n' 2>/dev/null | sort -rn)

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

main() {
  _chain_parse_args "$@"
  cross_run_id_ensure
  _chain_resolve_final_image
  _chain_validate_stages       # may exit for --describe-chain / --verify-chain
  _chain_no_push_guard         # refuse --no-push multi-stage (stale parent)
  _chain_prepare_log_dir
  _chain_archive_prev_logs
  _chain_prune_archived_logs
  _chain_write_pidfile         # read by stop-cross-chain.sh
  _chain_install_lifecycle_traps
  # Mint the OCI handoff workdir HERE. Every other caller reaches it through a
  # $(...) subshell, so the assignment would never reach this process and the
  # handoff would silently never activate. docs/cross-build-verification.md
  cross_local_handoff_enabled && cross_ensure_local_context_workdir
  _chain_assert_ancestry
  _chain_disk_preflight
  _chain_start_resource_monitor
  _chain_run_build_loop

  log "Cross chain complete."
}

main "$@"
