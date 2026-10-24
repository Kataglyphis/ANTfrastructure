#!/usr/bin/env bash
set -euo pipefail

# Forwards to build-cross-chain.sh --verify-chain, the one owner of the stage graph.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  # Loading only function definitions keeps help independent of build initialization.
  source "${REPO_ROOT}/linux/scripts/01-core/runtime-build-fns.sh" || return 1
  cat <<'EOF'
Usage: verify-cross-chain.sh [options]

Resolve registry digests for every cross-lane stage transition and report
whether downstream images may be stale relative to their parent.  No builds
are performed.  Forwards to build-cross-chain.sh --verify-chain.

Options:
EOF
  runtime_usage_chain_arches
  runtime_usage_row '--image-repo REPO' 27 chain
  cat <<'EOF'
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
