#!/usr/bin/env bash
set -euo pipefail

# verify-cross-chain.sh
#
# Standalone cross-chain staleness verification.  Resolves registry digests for
# every stage transition in the cross lane and reports whether downstream images
# may be stale relative to their declared parent.  No builds are performed.
#
# Thin forwarder: the staleness/describe logic (and its arg parser) lives in
# build-cross-chain.sh behind --verify-chain / --describe-chain, so the stage
# graph and digest resolution are defined in exactly one place.  This script
# just maps its own CLI onto that entry point.
#
# Usage:
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64
#   bash linux/scripts/verify-cross-chain.sh --target-arches arm64
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64 --image-repo ghcr.io/myorg/kataglyphis_beschleuniger
#   bash linux/scripts/verify-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'EOF'
Usage: verify-cross-chain.sh [options]

Resolve registry digests for every cross-lane stage transition and report
whether downstream images may be stale relative to their parent.  No builds
are performed.  Forwards to build-cross-chain.sh --verify-chain.

Options:
  --target-arches LIST     Comma-separated arch list (default: amd64,arm64,riscv64)
  --architectures LIST     Alias for --target-arches
  --image-repo REPO        Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --describe-chain          Print the full stage graph with tag names
  -h, --help               Show this help text
EOF
}

MODE_FLAG="--verify-chain"
FWD_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --describe-chain) MODE_FLAG="--describe-chain"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) FWD_ARGS+=("$1"); shift ;;
  esac
done

exec bash "${REPO_ROOT}/linux/scripts/build-cross-chain.sh" \
  "${MODE_FLAG}" ${FWD_ARGS[@]+"${FWD_ARGS[@]}"}
