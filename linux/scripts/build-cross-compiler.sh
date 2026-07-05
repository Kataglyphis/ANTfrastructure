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

# shellcheck source=linux/scripts/lib-orchestrator.sh
source "${REPO_ROOT}/linux/scripts/lib-orchestrator.sh"
orchestrator_preamble

# CROSS_TARGETS is the compiler target arch list — distinct from TARGET_ARCHES
# which is used for which arches to build per-arch stages for.
CROSS_TARGETS="${CROSS_TARGETS:-${CROSS_DEFAULT_ARCHES}}"

PUSH_IMAGES=0

usage() {
  cat <<'EOF'
Usage: build-cross-compiler.sh [options]

Builds an amd64-hosted cross-compiler image containing cross toolchains for all
target architectures.  Internally delegates to the shared stage graph
(stage-defs.sh) — same pipeline as build-cross-chain.sh and build-cross-stage.sh.

The image stays local unless --push is requested.  The amd64 base stage is
always built first via the shared stage graph, then the compiler stage is built
on top of it (with --push both stages are pushed and digest-pinned).

Options:
  --cross-targets LIST   Comma-separated target list (default: amd64,arm64,riscv64)
  --image-repo REPO      Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --push                 Push the compiler image to the registry with digest pinning
  --dry-run              Print build commands without executing them
EOF
  orchestrator_usage_mirror_options
  cat <<'EOF'
  -h, --help             Show this help text

Examples:
  # Build locally (no push), fast mirror:
  bash linux/scripts/build-cross-compiler.sh \
    --cross-targets amd64,arm64,riscv64 --fast-ubuntu-mirror \
    --fast-ubuntu-mirror-url http://de.archive.ubuntu.com/ubuntu/

  # Build and push:
  bash linux/scripts/build-cross-compiler.sh \
    --cross-targets amd64,arm64,riscv64 --push

  # Rebuild with a different image repo:
  bash linux/scripts/build-cross-compiler.sh \
    --image-repo ghcr.io/myorg/kataglyphis_beschleuniger --push

Environment overrides:
  NERDCTL_BIN            nerdctl executable to use
  USE_FAST_UBUNTU_MIRROR Set to true to replace Ubuntu mirrors
  FAST_UBUNTU_MIRROR_URL Mirror URL used when fast mirror is enabled
  FAST_UBUNTU_PORTS_MIRROR_URL Optional ports mirror URL
EOF
}

# ── Main ──────────────────────────────────────────────────────────────────────
_compiler_extra_arg() {
  case "$1" in
    --cross-targets) CROSS_TARGETS="$2"; _OARG_SHIFT=2 ;;
    *) return 1 ;;
  esac
}

main() {
  # Bind the shared parser's --target-arches arg to CROSS_TARGETS for this script
  run_orchestrator_arg_loop usage _compiler_extra_arg \
    CROSS_TARGETS USE_FAST_UBUNTU_MIRROR FAST_UBUNTU_MIRROR_URL \
    FAST_UBUNTU_PORTS_MIRROR_URL IMAGE_REPO _cross_vulkan_version PUSH_IMAGES \
    "$@"

  cd "${REPO_ROOT}"

  log "Cross-compiler build: targets=${CROSS_TARGETS} repo=${IMAGE_REPO} push=${PUSH_IMAGES}"

  # Build base first, then compiler, via the shared stage graph. cross_stage_run
  # handles digest-pinned parent resolution and pin capture, so on the push path
  # the compiler always consumes the freshly pushed base digest. The push flag is
  # forwarded verbatim (1=push both, 0=local-only).
  cross_stage_run "base" "" "${PUSH_IMAGES}"
  cross_stage_run "compiler" "" "${PUSH_IMAGES}"
}

main "$@"
