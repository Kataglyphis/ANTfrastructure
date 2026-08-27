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
# STALE-LOG (2026-08-23): both log-hygiene guards — cross_stage_log_redirect's
# truncate-on-new-run marker and _chain_archive_prev_logs below — hang off
# LOG_DIR, and while it defaulted EMPTY they were INERT for every run launched
# without --log-dir: no per-stage log was written at all, so nothing was ever
# truncated or archived. Wave5j's failed android-*.log (run
# 20260822-155127-8fd813db) therefore still sat in out/build-logs while wave5k
# and wave5o ran — both of those transcripts show the resource-monitor CSV
# landing in the REPO ROOT, i.e. LOG_DIR empty — and a watcher grepping those
# per-arch logs alarmed on wave5j's errors as if they were new (historically the
# same append-forever behavior produced stale-GREEN reads). Default to the
# location every doc already calls the standard one (README, AGENTS.md,
# docs/linux-cross-builds.md: out/build-logs), so the guards are armed by
# default and watchers need no mtime/baseline hack. `--log-dir ""` opts back
# out: no per-stage logs, no per-run archiving, and the resource-monitor CSV
# falls back to the repo root exactly as before. chain-status.json does NOT
# move with LOG_DIR — it stays pinned to the repo root, see _chain_status_emit.
#
# Moving the logs here also made the archive a real disk consumer (it reached
# 12G / 40 run dirs before anyone looked), so archiving is bounded by
# CROSS_LOG_ARCHIVE_KEEP — see _chain_prune_archived_logs.
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/out/build-logs}"

FROM_STAGE="base"
TO_STAGE="runtime"
VERIFY_CHAIN_ONLY=0
DESCRIBE_CHAIN=0
MAX_PARALLEL_ARCHS="${MAX_PARALLEL_ARCHS:-$(nproc 2>/dev/null || echo 4)}"
# PAR3 (2026-08-18): --parallel-archs pays off very differently per stage
# (sdk measured ~2.9x faster parallel; media was SLOWER than sequential until
# the PAR2 cache-mount id split). PARALLEL_STAGES limits which per-arch stages
# actually run parallel: "all" (default) or a csv like "sdk,android" — stages
# not listed run sequentially even under --parallel-archs.
PARALLEL_STAGES="${PARALLEL_STAGES:-all}"

# True when ${1} may run its arches in parallel under --parallel-archs.
_stage_parallel_allowed() {
  [ "${PARALLEL_STAGES}" = "all" ] && return 0
  case ",${PARALLEL_STAGES}," in *",$1,"*) return 0 ;; esac
  return 1
}

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
    --no-push) CROSS_NO_PUSH=1; export CROSS_NO_PUSH; _OARG_SHIFT=1
      warn "--no-push: on OCI-worker hosts the FROM handoff resolves against the REGISTRY, not the local store — downstream stages may build on the last PUSHED parent (see usage). Verified live 2026-08-08." ;;
    --no-verify-ancestry) CROSS_VERIFY_ANCESTRY=0; _OARG_SHIFT=1 ;;
    *) return 1 ;;
  esac
}

_chain_parse_args() {
  ONLY_STAGE=""
  # O5 flag allowlist: --push is inert in the chain (every cross stage is ALWAYS
  # pushed — digest pinning needs the manifest in the registry; --no-push is the
  # real toggle). It used to sink silently into _chain_push_enabled; warn instead.
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
    # Exit non-zero on STALE links: `make verify-chain` used to exit 0 even
    # when it had just DETECTED staleness — an explicit verification that
    # cannot fail is not a verification (audit round 2, failure-path F20).
    # (The automatic partial-run protection is separate and HARD:
    # _chain_assert_ancestry refuses to build on stale ancestors.)
    if verify_cross_chain_staleness "${TARGET_ARCHES}"; then
      exit 0
    else
      exit 2
    fi
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

# O3 (backlog 2026-08-10): machine-readable chain progress. Workers persist
# pin/fail facts into PARALLEL_LOOP_FLAGDIR and the join DELETES them — until
# now the only progress record was 3M-line build logs. Emit a small
# chain-status.json (atomic tmp+mv, best-effort — a status file must never fail
# a build) at every stage start/ok/fail, with the digest pin where one has been
# captured. Consumers: humans, watchers, future dashboards.
#
# The path is pinned to the REPO ROOT and is deliberately INDEPENDENT of LOG_DIR
# (STALE-LOG 2026-08-23). It used to be ${LOG_DIR:-${REPO_ROOT}}/... — which,
# the moment LOG_DIR gained its out/build-logs default, would have moved the
# file and left the git-TRACKED repo-root copy frozen at whatever the previous
# run wrote (today: run 20260823-100747, "runtime": "ok"). A tracked, forever-
# green status file that no longer tracks anything is precisely the stale-GREEN
# artifact this item exists to kill, so the status file gets ONE canonical home
# that no --log-dir choice can move. CROSS_CHAIN_STATUS_FILE overrides it
# wholesale (absolute path, for tests and for out-of-tree callers).
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

# Fail-fast disk preflight. A from-base 3-arch rebuild once ENOSPC-died mid-run
# and wasted ~10h; refuse to launch when free space is clearly insufficient,
# scaled by arch count and how heavy the starting stage is, with a concrete prune
# hint. Override with FORCE_LOW_DISK=1 (downgrades to a warning); DISK_PREFLIGHT=0
# skips it entirely.
_chain_disk_preflight() {
  [ "${DISK_PREFLIGHT:-1}" = "1" ] || return 0
  # The runtime stage additionally fills RUNTIME_CONTEXT_ROOT (full base rootfs
  # + package OCI layout, tens of GB) — measure that filesystem too when it
  # differs, so the preflight guards BOTH growth points.
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

  # Runtime-context filesystem (only warn when it is a DIFFERENT fs than the
  # cache dir; same fs was already assessed above). ~30G per arch of rootfs +
  # OCI layout during the runtime stage.
  if [ -n "${rt_free_gb}" ] && [ "${rt_free_gb}" != "${free_gb}" ]; then
    local rt_need=$(( n_arch * 30 ))
    if [ "${rt_free_gb}" -lt "${rt_need}" ]; then
      log "DISK PREFLIGHT (runtime contexts): ${rt_free_gb}G free on ${rt_root} < ~${rt_need}G for ${n_arch} arch(es) — the runtime stage may ENOSPC there."
    fi
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

  # Phase 2 — TOTAL-size cap (backlog Batch 0): the slugs are unbounded
  # mode=max exports, and free-space pruning alone lets the dir quietly grow
  # to whatever the disk tolerates ACROSS runs (observed 143G+). Cap the
  # directory at CROSS_CACHE_MAX_GB (0 disables), same LRU order and same
  # still-to-run-stage protection as phase 1.
  local cap_gb="${CROSS_CACHE_MAX_GB:-250}"
  [ "${cap_gb}" -gt 0 ] 2>/dev/null || return 0
  local total_gb
  # `|| true` for the same reason as the bc_gb line ~86 lines above: `du` on a
  # missing cache dir exits non-zero, pipefail propagates it, and set -e kills
  # the orchestrator with a bare exit 1 right AFTER a stage succeeded. That fix
  # was applied there and missed here (found 2026-08-27). Live triggers:
  # NO_CACHE=1 (the mkdir is gated on it), a relocated BUILDKIT_CACHE_DIR, or a
  # --only runtime resume. The `[ -n ... ] || return 0` below handles empty.
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

# ── lifecycle: pidfile + signal-driven child reaping (Batch 5 / O1+O2) ─────────
#
# The chain spawns nerdctl/buildctl children (directly and inside
# run_parallel_arch_loop subshells). Before this, a TERM/INT to the orchestrator
# left those children running as orphans (observed 4× on 2026-08-10 — the manual
# pkill afterwards left zombies). These handlers write a pidfile at start,
# reap the whole child subtree on a signal, and remove the pidfile on exit.
#
# EXIT/TERM/INT/HUP only — never a RETURN trap (see the parallel-loop.sh:21-32
# corpse: a RETURN trap re-arms on the caller's return and corrupts unrelated
# returns under set -u).
#
# BASH TRAP-DEFERRAL CAVEAT (verified 2026-08-13): a per-arch stage runs the
# build in the BACKGROUND under run_parallel_arch_loop's builtin `wait`, which a
# signal interrupts — so the handler fires PROMPTLY there. A non-per-arch stage
# (base/compiler/runtime) runs the build as a FOREGROUND pipeline
# (`run … | tee logfile`), and bash defers a signal trap until a foreground
# pipeline finishes. A bare `kill -TERM <orchestrator>` during such a stage is
# therefore queued, not immediate. The robust, always-prompt way to stop a chain
# is linux/scripts/stop-cross-chain.sh: it reaps the nerdctl/buildctl subtree
# DIRECTLY (which returns the foreground pipeline and lets this deferred handler
# run its cleanup). A group-wide signal (Ctrl-C in the controlling terminal)
# reaches the children too and is likewise handled cleanly.
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

# EXIT fires on BOTH normal completion and after the signal handler exits.
# Do ONLY pidfile cleanup here: on a clean finish the build children have
# already exited and the backgrounded resource-monitor self-terminates via its
# --watch-pid. Reaping the subtree here would kill that monitor before it wrote
# its summary — so tree termination lives ONLY in the signal path. Every command
# is guarded so a cleanup hiccup cannot flip the script's real exit code.
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
  # Drop our traps and exit with the conventional 128+signum so the caller sees
  # a signalled termination (not a bare exit 1). Clearing EXIT here avoids a
  # redundant second cleanup pass.
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

# LOG_DIR now has a real default (see its assignment near the top), so create it
# ONCE, up front, and prove it is writable: the per-stage logs otherwise mkdir
# it lazily inside a command substitution under `set -e`, where a failing
# `: > ${f}` takes the whole orchestrator down instead of just skipping the log.
# An unwritable dir therefore disables logging (back to the pre-default
# behavior) rather than failing a multi-hour build.
_chain_prepare_log_dir() {
  [ -n "${LOG_DIR:-}" ] || return 0          # `--log-dir ""` = opt out
  if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [ ! -w "${LOG_DIR}" ]; then
    warn "log dir ${LOG_DIR} is not writable — per-stage logs and their per-run archiving are disabled; the resource-monitor CSV falls back to ${REPO_ROOT}"
    LOG_DIR=""
    return 0
  fi
  log "per-stage build logs -> ${LOG_DIR}/<stage>[-<arch>].log (--log-dir '' disables)"
}

# Eager per-run log archiving (O2): the per-stage ${LOG_DIR}/<stage>.log files
# are truncated LAZILY on first write of each run (cross_stage_log_redirect's
# .run marker). A watcher that peeked BEFORE a stage first wrote saw the PREVIOUS
# run's log and read a stale failure as current (the stale-watcher false-green
# class). Fix: at chain start, move any prior run's STAGE logs out of the
# LOG_DIR root into archive/<prior-run-id>/ — the stale files are namespaced
# away up front instead of overwritten in place.
#
# It does NOT empty the directory (it used to claim "the root only ever holds
# the CURRENT run" — no longer true, and it was never true for anything but
# stage logs). LOG_DIR is now also where the operator's own nohup/tee chain
# transcripts and the resource-monitor CSVs live; only files this mechanism
# owns — a *.log with a sibling *.log.run marker — are moved, everything else
# is deliberately left where it is. See the marker-scoping note below.
_chain_archive_prev_logs() {
  [ -n "${LOG_DIR:-}" ] && [ -d "${LOG_DIR}" ] || return 0
  shopt -s nullglob
  local markers=( "${LOG_DIR}"/*.log.run )
  shopt -u nullglob
  # Marker-scoped, NOT every *.log in the directory: now that LOG_DIR defaults
  # to out/build-logs, that directory is also where the operator's own nohup/tee
  # transcript of the RUNNING chain lives (cross-chain-wave5o.log, 488M and
  # still growing while the chain runs). `mv`ing a file an open tee holds does
  # not stop the tee — it silently redirects the operator's live transcript
  # into archive/. A log this mechanism created always has a sibling
  # <name>.log.run marker, the same ownership test resource-monitor.sh's MON1
  # stage-log pick uses; a marker-less *.log belongs to somebody else. (A log
  # whose marker was deleted by hand is still safe: cross_stage_log_redirect
  # truncates on a missing marker.)
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

# Bounded archive retention (STALE-LOG 2026-08-23). _chain_archive_prev_logs
# above only ever ADDS, and now that LOG_DIR has a default it runs on EVERY
# chain start instead of only on --log-dir runs. When this was written
# out/build-logs was already 13G — 12G of that archive/, 40 run dirs, the
# largest single one 6.3G — on a filesystem at 92% used, i.e. on the box whose
# multi-hour builds die of ENOSPC. An unbounded archive is not log hygiene, it
# is a slow disk leak, so keep only the newest CROSS_LOG_ARCHIVE_KEEP run
# directories (default 5) and remove the older ones.
#
# THE DELETE IS DELIBERATELY BORING. Read the constraints, not the intent:
#   * the parent is the FIXED path ${LOG_DIR}/archive, and LOG_DIR is proven
#     non-empty before it is used anywhere in here;
#   * candidates are enumerated at DEPTH 1 ONLY (-mindepth 1 -maxdepth 1 -type
#     d), and find is used to READ names and mtimes — never -delete, never
#     -exec, never a `rm` on a glob. Each candidate is reduced to its LEAF NAME,
#     which must then match a RUN-ID shape, i.e. one of the two ids this
#     codebase actually produces: cross_run_id_generate's 8 digits '-' 6 digits
#     [-suffix], or a bare PID (cross-stage-build.sh writes the marker with
#     `rid="${CROSS_RUN_ID:-$$}"`, which is where the 6.3G archive/365161 came
#     from — the biggest dir on disk would be unreclaimable without it).
#     A leaf that matches can contain no '/', no '..' and no whitespace, so
#     "${arch_dir}/${leaf}" cannot address anything outside archive/ whatever
#     the directory happens to hold;
#   * every victim is re-tested immediately before removal: name non-empty,
#     parent non-empty, still a real directory, and NOT a symlink (a symlinked
#     run dir is skipped, never followed);
#   * anything else under archive/ — a differently-named sibling, a loose file,
#     a symlink, the current run — is never a candidate and never counts
#     against the keep budget;
#   * every removal is logged, so the transcript shows exactly what went.
# CROSS_LOG_ARCHIVE_KEEP=0 turns retention off (keep everything). A non-numeric
# value is refused rather than guessed at.
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

  # Run-id directories DIRECTLY under archive/, NEWEST FIRST, ordered by mtime.
  # Not by name: the two id shapes do not interleave lexically (a PID-named dir
  # sorts by its leading digit, so 365161 lands after every 2026* id and
  # 1847483 before them), and sorting the biggest, oldest dir on the box to the
  # "newest" end is exactly how a retention policy quietly reclaims nothing.
  # mtime is the same signal a human reads off `ls -lt`. `find` here only READS
  # names+mtimes at depth 1; nothing is deleted through it.
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
    # --dry-run prints what it would do and touches nothing. (The archiving mv
    # above predates this and still runs in dry-run; a mv is recoverable, an
    # `rm -rf` is not, so at minimum the irreversible half must be previewable.)
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
