#!/usr/bin/env bash
set -euo pipefail

# build-cross-chain.sh
#
# Orchestrates the full additive cross lane end-to-end with a digest-pinned
# stage handoff:
#
#   base -> compiler -> sdk -> media -> android -> runtime
#
# WHY THIS EXISTS
# ---------------
# Each cross stage is a separate `nerdctl build` whose next stage does
# `FROM ${BASE_IMAGE}`. If BASE_IMAGE is a mutable tag (e.g. :cross-media-arm64)
# the downstream build can silently consume a STALE locally-cached image instead
# of the freshly built/pushed one, because:
#   * `--output type=image,...,push=true` pushes the new digest to the registry
#     but does not reliably refresh the local containerd tag, and
#   * BuildKit's default FROM resolution prefers an already-present local image.
#
# This orchestrator removes that failure mode by capturing each stage's
# REGISTRY-resolvable manifest digest (via registry_pin_ref) right after it is
# pushed, and feeding it to the next stage as
# `--build-arg BASE_IMAGE=<repo>@sha256:<digest>`. A content-addressed digest
# can never resolve to a stale image.
#
# STAGE GRAPH
# -----------
# The cross-lane stage chain is defined declaratively in
# `linux/scripts/01-core/stage-defs.sh`.  Each stage entry has a Dockerfile,
# parent stage, tag function, and per-arch flag.  Both the build loop and
# `--verify-chain` consume the same graph, so the chain is defined in exactly
# one place.
#
# Every cross stage is pushed because digest pinning needs the manifest to exist
# in the registry.  This matches the documented cross flow, which already pushes
# base/compiler/sdk/media/android intermediates.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

FINAL_IMAGE="${FINAL_IMAGE:-${IMAGE_REPO}:latest-cross}"
# Set by --final-image so _chain_resolve_final_image can tell "user chose this"
# from "still the default". Comparing FINAL_IMAGE against the default string
# cannot distinguish the two, and silently overrode an explicit --final-image
# that happened to equal the default whenever --image-repo was also passed.
FINAL_IMAGE_SET=0
TARGET_ARCHES="$(resolve_arch_list)"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
LOG_DIR="${LOG_DIR:-}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DESCRIBE_CHAIN=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"

# Digest reference pins captured during this run.
# Variables are declared by cross_stage_init_pins() driven by the stage graph
# in stage-defs.sh.  They are accessed indirectly via cross_stage_pin_varname()
# + nameref in cross_stage_run().
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
  --verify-chain           Resolve all upstream digests and warn if downstream images are stale
  --no-verify-ancestry     Skip the stale-ancestor check that guards partial runs
                           (--from-stage after base). By default the chain refuses
                           to build on a parent that was re-pushed after the child
                           it would inherit. Env: CROSS_VERIFY_ANCESTRY=0
  --describe-chain          Print the full stage graph with tag names (no builds)
  --dry-run                 Print build commands without executing them
  --no-push                 Build every stage LOCALLY and skip all ghcr pushes
                            (validation runs: saves the slow multi-GB uploads; the
                            chain still resolves via the local image store)
  --parallel-archs          Build per-arch stages (sdk/media/android) in parallel
  --max-parallel-archs N    Max concurrent arch builds (default: 4)
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

# Runtime stage: delegates to build-runtime-manifest.sh to build per-arch
# base -> package -> torch -> wrapper images on the real target platform and
# publish the multi-arch :latest-cross manifest.
#
# Before delegating, ensures the parent stage images (cross-android-<arch>)
# are locally available.  Images built in this run are already present;
# images from prior builds are pulled from the registry.
run_runtime_stage() {
  cross_stage_ensure_parent_available "runtime" "${TARGET_ARCHES}"

  # Assemble args via shared function in cross-stage-build.sh (canonical source)
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
# This function reads _CROSS_CURRENT_STAGE (set before each parallel dispatch)
# to avoid redefining a function inside the stage loop. Bash function definitions
# are global; redefining inside a loop while background tasks are running would
# cause unpredictable stage-arch pairings.
_cross_per_arch_build() {
  local _arch="$1"
  cross_stage_run "${_CROSS_CURRENT_STAGE}" "${_arch}"
}

# ── chain verification ────────────────────────────────────────────────────────
#
# Both verify_cross_chain_staleness() and describe_cross_chain() are sourced from
# linux/scripts/01-core/chain-verify.sh (loaded via artifact-common.sh).
# No local _verify_link() / verify_chain() definitions needed.

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
    --no-push) CROSS_NO_PUSH=1; export CROSS_NO_PUSH; _OARG_SHIFT=1 ;;
    --no-verify-ancestry) CROSS_VERIFY_ANCESTRY=0; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

_chain_parse_args() {
  ONLY_STAGE=""
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
  # The default FINAL_IMAGE was computed from the default IMAGE_REPO, so it must
  # be recomputed when --image-repo moved the repo. An explicit --final-image
  # always wins, even when it happens to equal the default.
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
    verify_cross_chain_staleness "${TARGET_ARCHES}"
    exit 0
  fi
}

# Refuse to resume a chain on top of a stale ancestor.
#
# Digest pinning makes a SINGLE run internally consistent; it cannot see that
# e.g. the compiler was re-pushed after the sdk that a `--from-stage media` run
# is about to inherit. That case used to be guarded only by a rule in
# docs/linux-cross-builds.md; ancestry.sh checks it against the registry instead.
#
# Free for the common cases: a full --from-stage base run has no prior stages to
# verify and returns immediately.
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

_chain_run_build_loop() {
  cross_stage_validate_graph || err "Stage graph validation failed"

  # Drive execution from the stage graph (stage-defs.sh).
  # Each stage in CROSS_STAGE_ORDER is run only if it falls within the
  # [FROM_STAGE, TO_STAGE] range.  Stage build/pin functions are provided
  # by cross-stage-build.sh (sourced via artifact-common.sh).
  local stage
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    stage_enabled "${stage}" || continue

    # Explicit `|| err` on every stage: a failed stage MUST abort the chain,
    # never fall through to the next stage on a stale/missing upstream image.
    # set -e alone is unreliable here because the per-arch path runs under
    # run_parallel_arch_loop's `if !` (which disables set -e for the call tree).
    case "${stage}" in
      runtime)
        run_runtime_stage || err "runtime stage failed"
        ;;
      *)
        if cross_stage_is_per_arch "${stage}"; then
          _CROSS_CURRENT_STAGE="${stage}"
          run_parallel_arch_loop _cross_per_arch_build "$(arch_loop_flag_prefix cross-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}") \
            || err "stage ${stage} failed for one or more arches"
        else
          cross_stage_run "${stage}" || err "stage ${stage} failed"
        fi
        ;;
    esac
    # Reclaim regenerable cache between stages if the host is running low, so the
    # next (heavier) stage doesn't ENOSPC. No-op above CROSS_DISK_GUARD_GB free.
    _chain_stage_disk_guard "${stage}"
  done
}

# Fail-fast disk preflight. A from-base 3-arch rebuild once ENOSPC-died mid-run
# and wasted ~10h; refuse to launch when free space is clearly insufficient,
# scaled by arch count and how heavy the starting stage is, with a concrete prune
# hint. Override with FORCE_LOW_DISK=1 (downgrades to a warning); DISK_PREFLIGHT=0
# skips it entirely.
_chain_disk_preflight() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
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
  # `|| true` is load-bearing: on a host that has never built (no cache dir yet)
  # `du` exits non-zero, pipefail propagates it, and `set -e` aborted the whole
  # orchestrator here with a bare exit 1 and no diagnostic — precisely on the
  # first from-base run. The cache size is advisory (a prune hint), never fatal.
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
}

# Between-stage disk safety valve. On a disk-constrained host the buildkit
# OCI-worker cache cannot be pruned mid-run (its records pin as non-reclaimable),
# and deleting an intermediate image tag frees ~nothing because the child stage
# shares its layers. The ONE regenerable space is the --cache-to local export.
#
# Policy (replaces the old wholesale `rm -rf ${bc_dir}/*`, which destroyed the
# very slugs the NEXT stage would have warm-started from):
#   1. Slugs belonging to stages still to run in THIS chain are protected.
#   2. Unprotected slugs are pruned oldest-mtime-first (LRU) only until free
#      space clears CROSS_DISK_GUARD_GB.
#   3. If pruning every prunable slug still leaves us short, stop paying for
#      NEW local cache exports for the rest of the run (skipping future exports
#      beats deleting past ones) via CROSS_NO_LOCAL_CACHE_EXPORT=1.
# Off with CROSS_DISK_GUARD_GB=0.

# Pure helpers (_disk_guard_pick_victim, _disk_guard_protected_slugs) live in
# 01-core/disk-guard.sh so linux/scripts/tests can unit-test them.
# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/disk-guard.sh"

_chain_stage_disk_guard() {
  local completed_stage="${1:-}"
  local threshold="${CROSS_DISK_GUARD_GB:-40}"
  [ "${threshold}" -gt 0 ] 2>/dev/null || return 0
  local bc_dir="${BUILDKIT_CACHE_DIR:-${HOME:-/root}/.cache/kata-buildcache}"
  local free_gb
  free_gb="$(_disk_guard_free_gb "${bc_dir}")"
  [ -n "${free_gb}" ] || return 0
  [ "${free_gb}" -lt "${threshold}" ] || return 0

  local protected victim
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
}

_chain_start_resource_monitor() {
  # Comprehensive, low-overhead system-resource logging for the whole run (best
  # effort; RESOURCE_MONITOR=0 disables). The monitor self-terminates via
  # --watch-pid when this orchestrator exits (no trap/cleanup needed here), and
  # writes resources-<run>.csv + a summary pinpointing peak RAM/disk pressure.
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

main() {
  _chain_parse_args "$@"
  _chain_resolve_final_image
  _chain_validate_stages
  _chain_assert_ancestry
  _chain_disk_preflight
  _chain_start_resource_monitor
  _chain_run_build_loop

  log "Cross chain complete."
}

main "$@"
