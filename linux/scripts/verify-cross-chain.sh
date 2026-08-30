#!/usr/bin/env bash
set -euo pipefail

# verify-cross-chain.sh — thin forwarder to build-cross-chain.sh --verify-chain.
# The stage graph and digest resolution live in exactly one place.

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
