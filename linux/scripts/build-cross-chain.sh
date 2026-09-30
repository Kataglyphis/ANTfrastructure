#!/usr/bin/env bash
set -euo pipefail

# Full cross lane with digest-pinned stage handoff. docs/linux-cross-builds.md#recommended-digest-pinned-orchestrator-build-cross-chainsh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

FINAL_IMAGE="${FINAL_IMAGE:-$(cross_final_image_tag)}"
# Set by --final-image: comparing against the default string cannot tell a chosen default apart.
FINAL_IMAGE_SET=0
TARGET_ARCHES="$(resolve_arch_list)"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
# A GPU wrapper carries the CUDA/ROCm runtime and GPU torch wheels, so budget more than the CPU 120G.
[ -z "${CROSS_GPU_VARIANT:-}" ] || : "${CROSS_RUNTIME_LANE_GB:=180}"
# A variant logs apart: stage log names repeat across chains, and archiving would move the default's history.
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/build-logs${CROSS_GPU_VARIANT:+/${CROSS_GPU_VARIANT}}}"

# A variant starts at gpu: base, compiler and sdk are shared, and only the default chain re-pushes them.
FROM_STAGE="base"
[ -z "${CROSS_GPU_VARIANT:-}" ] || FROM_STAGE="gpu"
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

# This run's digest pins, declared from the stage graph and read via nameref.
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

# Usage

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
  --final-image REF        Final multi-arch manifest ref (default: REPO:latest)
  --from-stage STAGE       First stage to run: base|compiler|sdk|[gpu|]media|android|runtime
                           (a variant chain defaults to, and must start at or after, gpu)
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

Variant chains (an ENVIRONMENT knob; ENABLE_NVIDIA/ENABLE_AMD=true imply it):
  CROSS_VARIANT=nvidia|rocm  gpu stage after the shared sdk, every later tag
                             -<variant>, publishes :latest-<variant>. Starts at gpu;
                             amd64 only; pushes only from linux/amd64.

Notes:
  * When resuming mid-chain (e.g. --from-stage media), the required upstream
    digest is resolved from the parent stage's current registry tag.
  * Digest pinning requires pushing each cross stage; this is mandatory and
    matches the existing documented cross flow.
  * For single-stage rebuilds, use build-cross-stage.sh instead:
      bash linux/scripts/build-cross-stage.sh --stage sdk --arch arm64 --push
EOF
}

# Runtime stage helpers

# Delegates to build-runtime-manifest.sh for per-arch wrapper images + manifest.
run_runtime_stage() {
  cross_stage_ensure_parent_available "runtime" "${TARGET_ARCHES}"

  local -a helper_args
  cross_stage_assemble_runtime_helper_args helper_args

  if is_dry_run; then
    log "[stage runtime] [DRY RUN] would run build-runtime-manifest.sh ${helper_args[*]}"
    return 0
  fi

  # A refusal is a stage failure, or the status file keeps claiming the runtime stage is running.
  _chain_runtime_lane_disk_gate || { _chain_status_emit runtime failed; return 1; }

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  # Under --no-push, copy from this run's exported android image, not the stale registry tag.
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

# Defined once: bash functions are global, so redefining one in the stage loop races live workers.
_cross_per_arch_build() {
  local _arch="$1"
  cross_stage_run "${_CROSS_CURRENT_STAGE}" "${_arch}"
}

# Main driver

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
      # Inform only; _chain_no_push_guard decides at run time.
      log "--no-push: full chains use the local OCI-layout stage handoff; mid-chain runs (--from-stage after base) are refused unless CROSS_NO_PUSH_FORCE=1." ;;
    --no-verify-ancestry) CROSS_VERIFY_ANCESTRY=0; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

_chain_parse_args() {
  ONLY_STAGE=""
  # --push is inert (every stage is pushed; --no-push is the toggle), so warn about it.
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
  # The default came from the default IMAGE_REPO; an explicit --final-image always wins.
  if [ "${FINAL_IMAGE_SET}" -eq 0 ]; then
    FINAL_IMAGE="$(cross_final_image_tag)"
  fi
}

# A variant chain's refusals (stage-defs.sh cross_variant_refusal says why).
_chain_validate_variant() {
  [ -n "${CROSS_GPU_VARIANT:-}" ] || return 0
  local why; why="$(cross_variant_refusal "${FROM_STAGE}" "${TARGET_ARCHES}")"
  [ -z "${why}" ] || err "${why}"
}

_chain_validate_stages() {
  FROM_STAGE_IDX="$(stage_index "${FROM_STAGE}")" || exit 1
  TO_STAGE_IDX="$(stage_index "${TO_STAGE}")" || exit 1
  if [ "${FROM_STAGE_IDX}" -gt "${TO_STAGE_IDX}" ]; then
    err "--from-stage (${FROM_STAGE}) is after --to-stage (${TO_STAGE})"
  fi

  _chain_validate_variant
  # The runtime lane reads it hours from now; a typo must stop the chain here.
  runtime_wheels_source_mode >/dev/null || exit 2
  hailo_validate_knobs || exit 2

  log "Cross chain: arches=${TARGET_ARCHES} stages=${FROM_STAGE}..${TO_STAGE} repo=${IMAGE_REPO}${CROSS_GPU_VARIANT:+ variant=${CROSS_GPU_VARIANT}} final=${FINAL_IMAGE}"

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

# Digest pinning only makes a single run consistent, so refuse to resume on a stale ancestor.
_chain_assert_ancestry() {
  if [ "${CROSS_VERIFY_ANCESTRY:-1}" != "1" ]; then
    log "ancestry verification disabled (CROSS_VERIFY_ANCESTRY=0)"
    return 0
  fi
  # Local-only runs never consult the registry, and a dry run builds nothing.
  if [ "${CROSS_NO_PUSH:-0}" = "1" ]; then
    return 0
  fi
  if is_dry_run; then
    return 0
  fi
  ancestry_assert_chain "${FROM_STAGE}" "${TARGET_ARCHES}" \
    || err "Stale ancestor — refusing to build on it (see the [ancestry] lines above). Restart from the oldest stage reported, or set CROSS_VERIFY_ANCESTRY=0 to accept it."
}

# BuildKit resolves FROM against the registry; a mid-chain --no-push resume has no local parent.
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

# chain-status.json lives at the repo root, not LOG_DIR: readers look there.
declare -A _CHAIN_STATUS=()
_chain_status_emit() {
  local stage="$1" status="$2"
  _CHAIN_STATUS["${stage}"]="${status}"
  local out="${CROSS_CHAIN_STATUS_FILE:-${REPO_ROOT:-.}/chain-status${CROSS_GPU_VARIANT:+-${CROSS_GPU_VARIANT}}.json}" tmp
  # A bare filename survives ${out%/*} unchanged, so treat it as the current directory.
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
    # Only after a runtime failure, so a green run's file stays byte-identical for consumers.
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
    # Explicit || err per stage: set -e is off under run_parallel_arch_loop's `if !`.
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
    # Reclaim cache before the next stage hits ENOSPC; no-op above CROSS_DISK_GUARD_GB free.
    _chain_stage_disk_guard "${stage}"
  done
}

# Fail-fast disk preflight. FORCE_LOW_DISK=1 downgrades; DISK_PREFLIGHT=0 skips.
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

  # ~30G per arch of rootfs + OCI layout on the runtime-context filesystem.
  if [ -n "${rt_free_gb}" ] && [ "${rt_free_gb}" != "${free_gb}" ]; then
    local rt_need=$(( n_arch * 30 ))
    if [ "${rt_free_gb}" -lt "${rt_need}" ]; then
      log "DISK PREFLIGHT (runtime contexts): ${rt_free_gb}G free on ${rt_root} < ~${rt_need}G for ${n_arch} arch(es) — the runtime stage may ENOSPC there."
    fi
  fi
}

# Disk guard: the --cache-to export is the only regenerable mid-run space (docs/build-cache-tiers.md).

# Pure helpers live in disk-guard.sh so the tests can unit-test them.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/disk-guard.sh"

# Run-id / pidfile / child-reaping primitives shared with stop-cross-chain.sh.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/chain-lifecycle.sh"

# The runtime lane refuses below ~120G, which the 40G between-stage default reaches too late.
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

# <bc_dir> <protected_var> <measure_fn> <keep_going_fn> <limit> <number_var>; undeletable slugs join protected or the loop spins.
_chain_evict_slugs() {
  local bc_dir="$1" measure="$3" keep_going="$4" limit="$5"
  local -n _prot_ref="$2"
  local -n _num_ref="$6"
  local victim

  _num_ref="$("${measure}" "${bc_dir}")"
  while [ -n "${_num_ref}" ] && "${keep_going}" "${_num_ref}" "${limit}"; do
    victim="$(_disk_guard_pick_victim "${bc_dir}" "${_prot_ref}")"
    [ -n "${victim}" ] || break
    log "[disk-guard]   pruning slug ${victim} ($(du -sh "${bc_dir}/${victim}" 2>/dev/null | cut -f1 || echo '?'))"
    rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
    if [ -e "${bc_dir}/${victim}" ]; then
      warn "[disk-guard]   could not remove ${victim}; skipping it"
      _prot_ref="${_prot_ref},${victim}"
    fi
    _num_ref="$("${measure}" "${bc_dir}")"
  done
}

# || true: du fails on a missing cache dir, which can legitimately be absent.
_chain_bc_free_gb()  { _disk_guard_free_gb "$1"; }
_chain_bc_total_gb() { du -s --block-size=1G "$1" 2>/dev/null | cut -f1 || true; }
_chain_num_below() { [ "$1" -lt "$2" ] && return 0; return 1; }
_chain_num_above() { [ "$1" -gt "$2" ] && return 0; return 1; }

_chain_stage_disk_guard() {
  local completed_stage="${1:-}"
  local threshold="${CROSS_DISK_GUARD_GB:-40}"
  local _rt_need
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local protected="" victim free_gb

  # Aim at what the next stage needs, not a fixed floor. docs/failure-modes.md#the-disk-guard-aims-at-the-wrong-number
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
      _chain_evict_slugs "${bc_dir}" protected _chain_bc_free_gb _chain_num_below "${threshold}" free_gb
      [ -n "${free_gb}" ] || return 0
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
    fi
  fi

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

# In-stage guards: the runtime lane is one stage, so the between-stage guard never fires in it.

_CHAIN_DISK_WATCH_PID=""

# Free-GB the runtime lane needs right now (arch count x concurrency).
_chain_runtime_lane_need_gb() {
  # The runtime lane builds arches serially, so --parallel-archs must not scale this.
  local n_arch
  n_arch="$(arch_list_to_words "${TARGET_ARCHES}" | wc -w)"
  _disk_guard_runtime_lane_need_gb "${CROSS_RUNTIME_LANE_GB:-120}" "${n_arch}" 0
}

# Refuse a runtime lane that cannot fit before hours are spent; FORCE_LOW_DISK and --dry-run precede the trim.
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
  # Before any wrapper build is the only point in the lane where the image store is reachable.
  _disk_guard_image_store_fallback "${bc_dir}" "${need}" "$(_disk_guard_stage_tags '' 1)" 0
  _disk_guard_reclaim_record "runtime-lane-entry" "${free_gb}" "${bc_dir}"
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0
  [ "${free_gb}" -lt "${need}" ] || return 0
  err "runtime lane refused: ${free_gb}G free, ~${need}G needed (${CROSS_RUNTIME_LANE_GB:-120}G per concurrent wrapper build). The 2026-09-01 run entered this lane with 88G and died 28 minutes later with 'no image was built'. Free space, then re-run with --from-stage runtime; or set FORCE_LOW_DISK=1 / CROSS_RUNTIME_LANE_GB=0 to accept the risk."
}

# The buildkit reclaim is filtered to type==regular so the cachemounts survive.
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
  # Pass $$: in the backgrounded subshell $PPID is our parent, not us.
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

# Gates after the per-arch wrapper loop, all skipped when one arch fails; see docs/build-cache-tiers.md § 3.3
_CHAIN_RUNTIME_GATES="wrapper-content-gate,verify-shipped-wrapper,runtime-image-smoke,assert_pinned_versions,manifest-coherence,manifest-completeness,manifest-freshness"
_CHAIN_ARCH_OUTCOMES=""
_CHAIN_GATES_NOT_RUN=""

# built-this-run | stale | missing, from the wrapper tag's run-id stamp like the coherence gate.
_chain_runtime_arch_state() {
  local arch="$1" rid
  rid="$(ancestry_recorded_run_id "${FINAL_IMAGE}-${arch}" 2>/dev/null || true)"
  if [ -z "${rid}" ]; then printf 'missing'
  elif [ "${rid}" = "${CROSS_RUN_ID:-}" ]; then printf 'built-this-run'
  else printf 'stale'; fi
}

# Sets globals, so call directly; a $(...) subshell would discard them.
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

# Lifecycle: never a RETURN trap (re-arms under set -u); bash defers TERM, so stop-cross-chain.sh reaps.
_CHAIN_PIDFILE=""
_CHAIN_SIGNAL_HANDLED=0

# Reads the pidfile directly: runs before _chain_write_pidfile.
_chain_live_sibling_pid() {
  local pf other
  pf="$(cross_chain_pidfile_path)"
  [ -f "${pf}" ] || return 0
  other="$(cat "${pf}" 2>/dev/null || true)"
  [ -n "${other}" ] && [ "${other}" != "$$" ] && kill -0 "${other}" 2>/dev/null || return 0
  printf '%s' "${other}"
}

# One chain at a time: the disk guard evicts whatever the running chain does not protect.
_chain_refuse_live_sibling() {
  is_dry_run && return 0
  local pf sib; pf="$(cross_chain_pidfile_path)"
  # noclobber makes check-and-claim atomic, so two chains started together cannot both pass.
  if ( set -o noclobber; printf '%s\n' "$$" > "${pf}" ) 2>/dev/null; then
    _CHAIN_PIDFILE="${pf}"; return 0
  fi
  sib="$(_chain_live_sibling_pid)"
  [ -z "${sib}" ] || err "another cross chain is running (pid ${sib}, ${pf}). Chains run strictly one at a time; wait for it, or stop it with linux/scripts/stop-cross-chain.sh."
  # A stale pidfile (its chain is gone): take it over.
  printf '%s\n' "$$" > "${pf}" 2>/dev/null && _CHAIN_PIDFILE="${pf}"
  return 0
}

_chain_write_pidfile() {
  _CHAIN_PIDFILE="$(cross_chain_pidfile_path)"
  # Already claimed by _chain_refuse_live_sibling (the non-dry-run path).
  [ "$(cat "${_CHAIN_PIDFILE}" 2>/dev/null || true)" = "$$" ] && return 0
  # Never clobber a live sibling's pidfile; stop-cross-chain.sh is the way to stop it.
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

# No reaping on EXIT: it would kill the resource-monitor before it writes its summary.
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

# Up front: a lazy mkdir inside a command substitution under set -e kills the orchestrator.
_chain_prepare_log_dir() {
  [ -n "${LOG_DIR:-}" ] || return 0          # `--log-dir ""` = opt out
  # A variant in the default log dir would archive the default chain's history as its own.
  if [ -n "${CROSS_GPU_VARIANT:-}" ] \
     && [ "$(realpath -m "${LOG_DIR}")" = "$(realpath -m "${REPO_ROOT}/out/build-logs")" ]; then
    LOG_DIR="${LOG_DIR%/}/${CROSS_GPU_VARIANT:-}"
    log "variant ${CROSS_GPU_VARIANT:-}: per-stage logs go to its own ${LOG_DIR}"
  fi
  if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [ ! -w "${LOG_DIR}" ]; then
    warn "log dir ${LOG_DIR} is not writable — per-stage logs and their per-run archiving are disabled; the resource-monitor CSV falls back to ${REPO_ROOT}"
    LOG_DIR=""
    return 0
  fi
  log "per-stage build logs -> ${LOG_DIR}/<stage>[-<arch>].log (--log-dir '' disables)"
}

# Eager: stage logs truncate lazily, so a watcher could read last run's log as current.
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
  # Marker-scoped: moving the operator's live tee transcript would redirect it.
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

# The run-id shape match keeps the composed path inside archive/; do not loosen it.
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

# Warn only: a forgotten CROSS_BUILD_PLATFORM silently builds emulated for hours, but that is legal.
_chain_warn_emulated_platform() {
  local want have
  want="$(cross_build_platform)"
  have="linux/$(build_arch_oci)"
  [ "${want}" = "${have}" ] && return 0
  warn "CROSS_BUILD_PLATFORM=${want} but this host is ${have} — every cross stage AND the runtime artifact-source will run under emulation. Set CROSS_BUILD_PLATFORM=${have} for a native build."
}

main() {
  _chain_parse_args "$@"
  cross_run_id_ensure
  _chain_resolve_final_image
  _chain_warn_emulated_platform
  _chain_validate_stages       # may exit for --describe-chain / --verify-chain
  _chain_no_push_guard         # refuse --no-push multi-stage (stale parent)
  _chain_refuse_live_sibling   # strictly serial: before any log/state write
  _chain_prepare_log_dir
  _chain_archive_prev_logs
  _chain_prune_archived_logs
  _chain_write_pidfile         # read by stop-cross-chain.sh
  _chain_install_lifecycle_traps
  # Mint the handoff workdir here: other callers run in $(...), which would lose the assignment.
  cross_local_handoff_enabled && cross_ensure_local_context_workdir
  _chain_assert_ancestry
  _chain_disk_preflight
  _chain_start_resource_monitor
  _chain_run_build_loop

  log "Cross chain complete."
}

main "$@"
