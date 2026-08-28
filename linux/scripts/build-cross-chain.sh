#!/usr/bin/env bash
set -euo pipefail

# build-cross-chain.sh — the full cross lane end to end with a digest-pinned
# stage handoff: base -> compiler -> sdk -> media -> android -> runtime.
# Stage graph: 01-core/stage-defs.sh (shared with --verify-chain). Why the
# handoff must be pinned by digest: docs/linux-cross-builds.md.

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
# STALE-LOG (2026-08-23): both log-hygiene guards hang off LOG_DIR and were INERT
# while it defaulted empty — watchers read a previous run's failures as current.
# `--log-dir ""` opts back out; chain-status.json does not move with it.
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/build-logs}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DESCRIBE_CHAIN=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"
# PAR3 (2026-08-18): parallelism pays off per stage (sdk ~2.9x; media was SLOWER
# until the PAR2 cache-mount id split). csv limits which stages go parallel.
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

# ── stage gating ──────────────────────────────────────────────────────────────

# Build the STAGE_INDEX map from CROSS_STAGE_ORDER (defined in stage-defs.sh).
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

# ── usage ─────────────────────────────────────────────────────────────────────

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
                            KNOWN LIMITATION (2026-08-08): on hosts where builds
                            run on BuildKit's OCI worker (this host), the next
                            stage's FROM does NOT see the locally built parent —
                            the worker has its own store and resolves the mutable
                            tag against the REGISTRY, silently building on the
                            last PUSHED parent. Safe for --only/single-stage and
                            script validation; NOT safe as a full-chain handoff
                            until the oci-layout build-context fix lands (see
                            docs/refactoring-backlog.md).
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

# ── runtime stage helpers ──────────────────────────────────────────────────────

# Runtime stage: delegates to build-runtime-manifest.sh for the per-arch
# base -> package -> torch -> wrapper images and the multi-arch manifest.
# Ensures the parent cross-android-<arch> images are locally available first.
run_runtime_stage() {
  cross_stage_ensure_parent_available "runtime" "${TARGET_ARCHES}"

  local -a helper_args
  cross_stage_assemble_runtime_helper_args helper_args

  if is_dry_run; then
    log "[stage runtime] [DRY RUN] would run build-runtime-manifest.sh ${helper_args[*]}"
    return 0
  fi

  log "[stage runtime] building package/torch/wrapper + manifest ${FINAL_IMAGE}"
  run env NERDCTL_BIN="${NERDCTL_BIN}" \
    bash "${REPO_ROOT}/linux/scripts/build-runtime-manifest.sh" "${helper_args[@]}"
}

# ── per-arch build helper (avoids function-redefinition race in loops) ─────────
#
# Reads _CROSS_CURRENT_STAGE instead of redefining a function inside the stage
# loop: bash definitions are global, so a redefinition would race live workers.
_cross_per_arch_build() {
  local _arch="$1"
  cross_stage_run "${_CROSS_CURRENT_STAGE}" "${_arch}"
}

# ── chain verification ────────────────────────────────────────────────────────
#
# verify_cross_chain_staleness() and describe_cross_chain() come from
# 01-core/chain-verify.sh (loaded via artifact-common.sh).

# ── main driver ───────────────────────────────────────────────────────────────

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
      warn "--no-push: on OCI-worker hosts the FROM handoff resolves against the REGISTRY, not the local store — downstream stages may build on the last PUSHED parent (see usage). Verified live 2026-08-08." ;;
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
    # Exit non-zero on STALE links: a verification that cannot fail is not a
    # verification (audit round 2, F20).
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

# O3: machine-readable chain progress — chain-status.json (atomic tmp+mv, best
# effort) at each stage start/ok/fail. Pinned to the REPO ROOT, NOT LOG_DIR — a
# moved file would freeze the tracked copy stale-GREEN. CROSS_CHAIN_STATUS_FILE overrides.
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
          || { _chain_status_emit "${stage}" "failed"; err "runtime stage failed"; }
        ;;
      *)
        if cross_stage_is_per_arch "${stage}"; then
          _CROSS_CURRENT_STAGE="${stage}"
          # PAR3: demote this stage to sequential when PARALLEL_STAGES excludes
          # it (save/restore — later stages decide independently).
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

# Fail-fast disk preflight: a from-base 3-arch rebuild once ENOSPC-died ~10h in.
# FORCE_LOW_DISK=1 downgrades to a warning; DISK_PREFLIGHT=0 skips it.
_chain_disk_preflight() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
  # The runtime stage also fills RUNTIME_CONTEXT_ROOT (tens of GB) — measure that
  # filesystem too when it differs, so both growth points are guarded.
  local rt_root="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/root}/.cache}/opencode/runtime-build-contexts}"
  local rt_free_gb
  rt_free_gb="$(_disk_guard_free_gb "${rt_root}")"
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local free_gb n_arch per_arch need_gb bc_gb
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
  if [ "${free_gb}" -lt "${need_gb}" ]; then
    log "DISK PREFLIGHT: ${free_gb}G free < ~${need_gb}G recommended (${n_arch} arch(es), from-stage ${FROM_STAGE})."
    [ -n "${bc_gb}" ] && [ "${bc_gb}" -gt 40 ] && \
      log "  Reclaim ~${bc_gb}G: rm -rf ${bc_dir}/* (regenerable cross-run cache export)."
    log "  Also: buildctl prune ; nerdctl --namespace default system prune -f."
    if [ "${FORCE_LOW_DISK:-0}" = "1" ]; then
      log "  FORCE_LOW_DISK=1 — continuing despite low disk (ENOSPC risk accepted)."
    else
      err "Insufficient disk: ${free_gb}G free, ~${need_gb}G recommended. Free space or set FORCE_LOW_DISK=1."
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

_chain_stage_disk_guard() {
  local completed_stage="${1:-}"
  local threshold="${CROSS_DISK_GUARD_GB:-40}"
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local protected="" victim free_gb

  if [ "${threshold}" -gt 0 ] 2>/dev/null; then
    free_gb="$(_disk_guard_free_gb "${bc_dir}")"
    if [ -n "${free_gb}" ] && [ "${free_gb}" -lt "${threshold}" ]; then
      protected="$(_disk_guard_protected_slugs "${completed_stage}")"
      log "[disk-guard] ${free_gb}G free < ${threshold}G after stage ${completed_stage:-?} — LRU-pruning cache exports in ${bc_dir} (protected: ${protected:-none})"
      while [ "${free_gb}" -lt "${threshold}" ]; do
        victim="$(_disk_guard_pick_victim "${bc_dir}" "${protected}")"
        [ -n "${victim}" ] || break
        log "[disk-guard]   pruning slug ${victim} ($(du -sh "${bc_dir}/${victim}" 2>/dev/null | cut -f1 || echo '?'))"
        rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
        free_gb="$(_disk_guard_free_gb "${bc_dir}")"
        [ -n "${free_gb}" ] || return 0
      done
      if [ "${free_gb}" -lt "${threshold}" ]; then
        log "[disk-guard] still ${free_gb}G free after pruning — skipping local cache exports for remaining stages (CROSS_NO_LOCAL_CACHE_EXPORT=1)"
        export CROSS_NO_LOCAL_CACHE_EXPORT=1
      else
        log "[disk-guard] after pruning: ${free_gb}G free"
      fi
    fi
  fi

  # Phase 2 — TOTAL-size cap: free-space pruning alone lets the dir grow across
  # runs (observed 143G+). Same LRU order and stage protection as phase 1.
  local cap_gb="${CROSS_CACHE_MAX_GB:-250}"
  [ "${cap_gb}" -gt 0 ] 2>/dev/null || return 0
  local total_gb
  # `|| true`: `du` on a missing cache dir exits non-zero and pipefail + set -e
  # would kill the orchestrator right after a stage succeeded (found 2026-08-27).
  # The dir really can be absent: NO_CACHE=1 gates the mkdir, as do a relocated
  # BUILDKIT_CACHE_DIR and a --only runtime resume.
  total_gb="$(du -s --block-size=1G "${bc_dir}" 2>/dev/null | cut -f1 || true)"
  [ -n "${total_gb}" ] && [ "${total_gb}" -gt "${cap_gb}" ] || return 0
  [ -n "${protected}" ] || protected="$(_disk_guard_protected_slugs "${completed_stage}")"
  log "[disk-guard] cache exports total ${total_gb}G > cap ${cap_gb}G — LRU-pruning ${bc_dir} down to the cap (protected: ${protected:-none})"
  while [ "${total_gb}" -gt "${cap_gb}" ]; do
    victim="$(_disk_guard_pick_victim "${bc_dir}" "${protected}")"
    [ -n "${victim}" ] || break
    log "[disk-guard]   pruning slug ${victim} ($(du -sh "${bc_dir}/${victim}" 2>/dev/null | cut -f1 || echo '?'))"
    rm -rf "${bc_dir:?}/${victim}" 2>/dev/null || true
    total_gb="$(du -s --block-size=1G "${bc_dir}" 2>/dev/null | cut -f1 || true)"
    [ -n "${total_gb}" ] || return 0
  done
  log "[disk-guard] cache exports now ${total_gb}G (cap ${cap_gb}G)"
}

_chain_start_resource_monitor() {
  # Low-overhead resource logging for the whole run; self-terminates via
  # --watch-pid. See docs/build-resource-monitoring.md. RESOURCE_MONITOR=0 disables.
  [ "${RESOURCE_MONITOR:-1}" = "1" ] || return 0
  local mon="${REPO_ROOT}/linux/scripts/01-core/resource-monitor.sh"
  [ -x "${mon}" ] || return 0
  local out="${LOG_DIR:-${REPO_ROOT}}" rid="${CROSS_RUN_ID:-cross}"
  # Idempotent: skip if a monitor is already sampling this run (e.g. started by
  # the launcher or a wrapping build-cross-stage.sh).
  pgrep -f "resource-monitor.sh.*${rid}" >/dev/null 2>&1 && return 0
  bash "${mon}" --out-dir "${out}" --run-id "${rid}" --stage-log-dir "${out}" \
    --disk-path "${BUILDKIT_CACHE_DIR:-/}" --watch-pid "$$" </dev/null >/dev/null 2>&1 &
  log "resource-monitor: sampling -> ${out}/resources-${rid}.csv (RESOURCE_MONITOR=0 to disable)"
}

# ── lifecycle: pidfile + signal-driven child reaping (Batch 5 / O1+O2) ─────────
#
# EXIT/TERM/INT/HUP only — never a RETURN trap (it re-arms on the caller's return
# and corrupts unrelated returns under set -u; see parallel-loop.sh).
# Bash defers a trap until a foreground pipeline finishes, so a bare TERM during a
# non-per-arch stage is queued — stop-cross-chain.sh reaps the child subtree
# directly instead (docs/cross-build-verification.md).
_CHAIN_PIDFILE=""
_CHAIN_SIGNAL_HANDLED=0

_chain_write_pidfile() {
  _CHAIN_PIDFILE="$(cross_chain_pidfile_path)"
  # A live SIBLING chain already owns this pidfile: warn (do not clobber its
  # ownership — the deliberate path to stop it is stop-cross-chain.sh).
  if [ -f "${_CHAIN_PIDFILE}" ]; then
    local other; other="$(cat "${_CHAIN_PIDFILE}" 2>/dev/null || true)"
    if [ -n "${other}" ] && [ "${other}" != "$$" ] && kill -0 "${other}" 2>/dev/null; then
      warn "another cross chain appears to be running (pid ${other}, pidfile ${_CHAIN_PIDFILE}); stop it with stop-cross-chain.sh. Continuing anyway."
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
_chain_on_exit() {
  _chain_remove_pidfile
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

# Eager per-run log archiving (O2): per-stage logs are truncated LAZILY on first
# write, so a watcher peeking earlier read the PREVIOUS run's log as current.
_chain_archive_prev_logs() {
  [ -n "${LOG_DIR:-}" ] && [ -d "${LOG_DIR}" ] || return 0
  shopt -s nullglob
  local markers=( "${LOG_DIR}"/*.log.run )
  shopt -u nullglob
  # Marker-scoped, NOT every *.log: LOG_DIR also holds the operator's own live
  # nohup/tee transcript, and mv-ing a file an open tee holds redirects it.
  [ "${#markers[@]}" -gt 0 ] || return 0
  # Derive the prior run id from any surviving .run marker, else a timestamp.
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

# Bounded archive retention (STALE-LOG 2026-08-23): _chain_archive_prev_logs only
# ever ADDS (12G / 40 run dirs once), so keep the newest CROSS_LOG_ARCHIVE_KEEP
# (default 5, 0 = off). Depth-1 only, symlinks skipped, and the leaf must match a
# run-id shape (timestamp or bare PID) — that shape is what keeps the composed
# path inside archive/, so do not loosen it to catch some other directory name.
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
  cross_run_id_ensure          # O2: one canonical CROSS_RUN_ID for all consumers
  _chain_resolve_final_image
  _chain_validate_stages       # may exit 0 for --describe-chain / --verify-chain
  _chain_prepare_log_dir       # STALE-LOG: create/verify LOG_DIR before anyone writes
  _chain_archive_prev_logs     # O2: eager per-run log archiving (before any write)
  _chain_prune_archived_logs   # STALE-LOG: bound archive/ (CROSS_LOG_ARCHIVE_KEEP)
  _chain_write_pidfile         # O2: pidfile read by stop-cross-chain.sh
  _chain_install_lifecycle_traps  # O1: reap nerdctl/buildctl children on signal
  _chain_assert_ancestry
  _chain_disk_preflight
  _chain_start_resource_monitor
  _chain_run_build_loop

  log "Cross chain complete."
}

main "$@"
