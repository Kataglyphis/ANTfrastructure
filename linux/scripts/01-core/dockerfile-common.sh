#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: dockerfile-common.sh <command>

Commands:
  configure-fast-mirror
EOF
}

main() {
  local command="${1:-}"

  case "${command}" in
    configure-fast-mirror)
      shift
      exec bash "${SCRIPT_DIR}/use-fast-ubuntu-mirror.sh" "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
