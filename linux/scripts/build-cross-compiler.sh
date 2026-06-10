#!/usr/bin/env bash
set -euo pipefail

# build-cross-compiler.sh
#
# Standalone entry point to build the cross-compiler image.  Internally delegates
# to the shared stage-defs.sh graph (same pipeline as the orchestrator and
# build-cross-stage.sh) so the compiler stage is defined in exactly one place.
#
# When --push is used, the parent (base) is digest-pinned to avoid stale reuse.
# Without --push, the image stays local and the parent is resolved from either
# the local tag or the current registry tag.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"
IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"
init_mirror_defaults

REBUILD_BASE=0
PUSH_IMAGE=0
DRY_RUN=0

# ── Backward-compatible env var overrides (prefer --image-repo instead) ───────
# These are resolved in _refresh_tags() after CLI parsing so IMAGE_REPO is final.
_LEGACY_BASE_TAG="${BASE_REMOTE_TAG:-}"
_LEGACY_COMPILER_TAG="${COMPILER_REMOTE_TAG:-}"
_legacy_base_tag()  { [ -n "${_LEGACY_BASE_TAG}" ] && printf '%s' "${_LEGACY_BASE_TAG}" || cross_base_tag; }
_legacy_compiler_tag() { [ -n "${_LEGACY_COMPILER_TAG}" ] && printf '%s' "${_LEGACY_COMPILER_TAG}" || cross_compiler_tag; }

usage() {
  cat <<'EOF'
Usage: build-cross-compiler.sh [options]

Builds an amd64-hosted cross-compiler image containing cross toolchains for all
target architectures.  Internally delegates to the shared stage graph
(stage-defs.sh) — same pipeline as build-cross-chain.sh and build-cross-stage.sh.

The image stays local unless --push is requested.  If the remote base image is
unavailable, the script builds a local amd64 base image first and then uses it
for the compiler build.

Options:
  --cross-targets LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --image-repo REPO      Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --push                 Push the compiler image to the registry with digest pinning
  --rebuild-base         Always rebuild the local base image instead of trying pull first
  --dry-run              Print build commands without executing them
  --fast-ubuntu-mirror   Replace Ubuntu archive/security/ports mirrors during builds
  --fast-ubuntu-mirror-url URL        Archive mirror URL
  --fast-ubuntu-ports-mirror-url URL  Optional ubuntu-ports mirror URL
  -h, --help             Show this help text

Examples:
  # Build locally (no push), fast mirror:
  bash linux/scripts/build-cross-compiler.sh \\
    --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \\
    --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/

  # Build and push:
  bash linux/scripts/build-cross-compiler.sh \\
    --cross-targets amd64,arm64,riscv64 --push

  # Rebuild with a different image repo:
  bash linux/scripts/build-cross-compiler.sh \\
    --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

Environment overrides (legacy — prefer --image-repo for the repo prefix):
  BASE_REMOTE_TAG        Override base image tag (default: REPO:base)
  COMPILER_REMOTE_TAG    Override compiler image tag (default: REPO:cross-compiler-amd64)
  NERDCTL_BIN            nerdctl executable to use
  USE_FAST_UBUNTU_MIRROR Set to true to replace Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL
EOF
}

# ── Base image bootstrap ──────────────────────────────────────────────────────
# Uses ensure_local_image() from build-helpers.sh to pull or build the base.
ensure_base_image() {
  local base_tag remote_tag
  base_tag="$(cross_base_tag)"
  remote_tag="${_LEGACY_BASE_TAG:-${base_tag}}"

  local -a build_args=()
  append_common_build_args build_args

  ensure_local_image "${base_tag}" \
    "$(cross_stage_dockerfile base)" \
    "${remote_tag}" \
    build_args
}

# ── Compiler build ────────────────────────────────────────────────────────────
# build_compiler: delegates to the shared cross_stage_run() from the stage graph.
# When pushing, the base parent is digest-pinned (no stale reuse).  When staying
# local, the mutable base tag is used (safe since no downstream can be affected).
build_compiler() {
  cross_stage_run "compiler" "" "${PUSH_IMAGE}"
}

# ── Push (local-only path) ────────────────────────────────────────────────────
push_compiler() {
  local compiler_tag
  compiler_tag="$(_legacy_compiler_tag)"
  if [ "${compiler_tag}" != "$(cross_compiler_tag)" ]; then
    run "${NERDCTL_BIN}" tag "$(cross_compiler_tag)" "${compiler_tag}"
  fi
  retry 3 10 "pushing compiler image" \
    run "${NERDCTL_BIN}" push "${compiler_tag}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  while [ $# -gt 0 ]; do
    local _dispatch_rc=0
    dispatch_parsed_args parse_shared_orchestrator_args \
      CROSS_TARGETS USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
      FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO _ignored_vulkan PUSH_IMAGE \
      "$1" "${2:-}" || _dispatch_rc=$?
    case $_dispatch_rc in
      255) usage; exit 0 ;;
      0) case "${_DP_SHIFT}" in
           1) shift 1; continue ;;
           2) shift 2; continue ;;
         esac ;;
    esac
    case "$1" in
      --cross-targets)
        CROSS_TARGETS="$2"
        shift 2
        ;;
      --rebuild-base)
        REBUILD_BASE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      *)
        warn "Unknown option: $1"
        usage >&2
        exit 1
        ;;
    esac
  done

  cd "${REPO_ROOT}"

  log "Cross-compiler build: targets=${CROSS_TARGETS} repo=${IMAGE_REPO} push=${PUSH_IMAGE}"

  if [ "${PUSH_IMAGE}" -eq 1 ]; then
    # Push path: build and push both base and compiler via the stage graph.
    # cross_stage_run handles digest-pinned parent resolution and pin capture,
    # so the compiler always consumes the freshly pushed base digest.
    cross_stage_run "base" "" 1
    cross_stage_run "compiler" "" 1
    if [ "${DRY_RUN}" -eq 0 ]; then
      push_compiler
    fi
  else
    # Local path: ensure base exists locally (try pull first, build if needed),
    # then build compiler locally via the stage graph.
    ensure_base_image
    cross_stage_run "compiler" "" 0
  fi
}

main "$@"
