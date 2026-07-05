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
  --describe-chain          Print the full stage graph with tag names (no builds)
  --dry-run                 Print build commands without executing them
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
    --final-image) FINAL_IMAGE="$2"; _OARG_SHIFT=2 ;;
    --from-stage) FROM_STAGE="$2"; _OARG_SHIFT=2 ;;
    --to-stage) TO_STAGE="$2"; _OARG_SHIFT=2 ;;
    --only) ONLY_STAGE="$2"; _OARG_SHIFT=2 ;;
    --log-dir) LOG_DIR="$2"; _OARG_SHIFT=2 ;;
    --verify-chain) VERIFY_CHAIN_ONLY=1; _OARG_SHIFT=1 ;;
    --describe-chain) DESCRIBE_CHAIN=1; _OARG_SHIFT=1 ;;
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
  # Default FINAL_IMAGE may reference the previous IMAGE_REPO default; recompute
  # it if the user changed --image-repo but not --final-image.
  if [ "${FINAL_IMAGE}" = "${IMAGE_REGISTRY_PREFIX}:latest-cross" ]; then
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

_chain_run_build_loop() {
  cross_stage_validate_graph || err "Stage graph validation failed"

  # Drive execution from the stage graph (stage-defs.sh).
  # Each stage in CROSS_STAGE_ORDER is run only if it falls within the
  # [FROM_STAGE, TO_STAGE] range.  Stage build/pin functions are provided
  # by cross-stage-build.sh (sourced via artifact-common.sh).
  local stage
  for stage in "${CROSS_STAGE_ORDER[@]}"; do
    stage_enabled "${stage}" || continue

    case "${stage}" in
      runtime)
        run_runtime_stage
        ;;
      *)
        if cross_stage_is_per_arch "${stage}"; then
          _CROSS_CURRENT_STAGE="${stage}"
          run_parallel_arch_loop _cross_per_arch_build "$(arch_loop_flag_prefix cross-loop-flags)" "${MAX_PARALLEL_ARCHS}" $(arch_list_to_words "${TARGET_ARCHES}")
        else
          cross_stage_run "${stage}"
        fi
        ;;
    esac
  done
}

main() {
  _chain_parse_args "$@"
  _chain_resolve_final_image
  _chain_validate_stages
  _chain_run_build_loop

  log "Cross chain complete."
}

main "$@"
