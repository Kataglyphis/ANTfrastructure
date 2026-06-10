#!/usr/bin/env bash
set -euo pipefail

# verify-cross-chain.sh
#
# Standalone cross-chain staleness verification.  Resolves registry digests for
# every stage transition in the cross lane and reports whether downstream images
# may be stale relative to their declared parent.
#
# This uses the shared verify_cross_chain_staleness() from chain-verify.sh
# (sourced via artifact-common.sh).  No builds are performed.
#
# Usage:
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64
#   bash linux/scripts/verify-cross-chain.sh --target-arches arm64
#   bash linux/scripts/verify-cross-chain.sh --target-arches amd64,arm64,riscv64 --image-repo ghcr.io/myorg/kataglyphis_beschleuniger
#   bash linux/scripts/verify-cross-chain.sh --describe-chain --target-arches amd64,arm64,riscv64

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/linux/scripts/01-core/artifact-common.sh"

IMAGE_REPO="${IMAGE_REPO:-${IMAGE_REGISTRY_PREFIX}}"
TARGET_ARCHES="$(resolve_arch_list)"

DESCRIBE_CHAIN=0

usage() {
  cat <<'EOF'
Usage: verify-cross-chain.sh [options]

Resolve registry digests for every cross-lane stage transition and report
whether downstream images may be stale relative to their parent.  No builds
are performed.

Options:
  --target-arches LIST     Comma-separated arch list (default: amd64,arm64,riscv64)
  --architectures LIST     Alias for --target-arches
  --image-repo REPO        Image repository (default: ghcr.io/kataglyphis/kataglyphis_beschleuniger)
  --describe-chain          Print the full stage graph with tag names
  -h, --help               Show this help text
EOF
}

main() {
  while [ $# -gt 0 ]; do
    consume_shared_arg usage \
      parse_shared_orchestrator_args \
      TARGET_ARCHES _ _ _ IMAGE_REPO _ _ \
      "$1" "${2:-}" || break
    case "${_DP_SHIFT}" in
      1) shift; continue ;;  2) shift 2; continue ;;
    esac
    case "$1" in
      --describe-chain) DESCRIBE_CHAIN=1; shift ;;
      *) warn "Unknown option: $1"; usage >&2; exit 1 ;;
    esac
  done

  cd "${REPO_ROOT}"
  TARGET_ARCHES="$(normalize_target_arches "${TARGET_ARCHES}")"

  cross_stage_validate_graph || err "Stage graph validation failed"

  if [ "${DESCRIBE_CHAIN}" -eq 1 ]; then
    describe_cross_chain "${TARGET_ARCHES}"
    exit 0
  fi

  verify_cross_chain_staleness "${TARGET_ARCHES}"
}

main "$@"
