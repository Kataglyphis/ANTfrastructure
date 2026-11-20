#!/usr/bin/env bash
# ANT_CARGO_RELEASE_JSON_API=1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cargo_release_prepare_messages() {
  : "${CARGO_RELEASE_WORKSPACE_MESSAGES:=}" "${CARGO_RELEASE_CLI_MESSAGES:=}"
  case "${CARGO_RELEASE_WORKSPACE_MESSAGES:+set}:${CARGO_RELEASE_CLI_MESSAGES:+set}" in
    :) return 0 ;;
    set:set) ;;
    *) printf 'Both Cargo release JSON paths are required\n' >&2; return 2 ;;
  esac
  CARGO_RELEASE_WORKSPACE_MESSAGES="$(realpath -m -- "${CARGO_RELEASE_WORKSPACE_MESSAGES}")"
  CARGO_RELEASE_CLI_MESSAGES="$(realpath -m -- "${CARGO_RELEASE_CLI_MESSAGES}")"
  if [[ "${CARGO_RELEASE_WORKSPACE_MESSAGES}" == "${CARGO_RELEASE_CLI_MESSAGES}" ||
        "${CARGO_RELEASE_WORKSPACE_MESSAGES}" -ef "${CARGO_RELEASE_CLI_MESSAGES}" ]]; then
    printf 'Cargo release JSON paths must identify different files\n' >&2
    return 2
  fi
  local _crj_messages
  for _crj_messages in "${CARGO_RELEASE_WORKSPACE_MESSAGES}" "${CARGO_RELEASE_CLI_MESSAGES}"; do
    if [[ -e "${_crj_messages}" && ! -f "${_crj_messages}" ]]; then
      printf 'Cargo release JSON output must be a regular file: %s\n' "${_crj_messages}" >&2
      return 2
    fi
  done
  for _crj_messages in "${CARGO_RELEASE_WORKSPACE_MESSAGES}" "${CARGO_RELEASE_CLI_MESSAGES}"; do
    mkdir -p -- "$(dirname -- "${_crj_messages}")"
    : > "${_crj_messages}"
  done
  return 0
}

# Failed wrapper setup must invalidate both old metadata streams before it can stop the build.
_cargo_release_prepare_messages
# Logging, the CARGO_HOME and toolchain guards, safe.directory and the opt-in linker, one copy for every driver.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/_cargo_wrapper.sh"

info "Running cargo release build..."
# Build all workspace members including binaries
if [[ -n "${CARGO_RELEASE_WORKSPACE_MESSAGES}" ]]; then
  cargo build --message-format=json-render-diagnostics --release --workspace "$@" > "${CARGO_RELEASE_WORKSPACE_MESSAGES}"
else
  cargo build --release --workspace "$@"
fi

# Explicitly build the CLI binary to ensure it's available for packaging
info "Building CLI binary..."
if [[ -n "${CARGO_RELEASE_CLI_MESSAGES}" ]]; then
  cargo build --message-format=json-render-diagnostics --release -p kataglyphis_cli "$@" > "${CARGO_RELEASE_CLI_MESSAGES}"
else
  cargo build --release -p kataglyphis_cli "$@"
fi

info "Release build completed successfully."
