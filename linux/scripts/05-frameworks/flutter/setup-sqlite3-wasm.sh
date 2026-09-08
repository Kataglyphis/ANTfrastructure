#!/usr/bin/env bash
# setup-sqlite3-wasm.sh - fetch the pinned sqlite3.wasm into a consumer's web/.

# A Flutter web app that uses sqlite cannot start without this asset. Two
# consumers had copied the same 16-line curl and had already drifted apart on
# the version, and neither verified what it downloaded - an unauthenticated
# binary that then executes in every visitor's browser. The version and its
# SHA256 now live in 01-core/versions.env, and the fetch goes through
# download_verified_file, so a tampered or truncated asset fails HERE.
#
#   setup-sqlite3-wasm.sh <consumer-root>

# The consumer root is MANDATORY and never inferred: this script runs from
# inside third_party/ContainerHub, where a BASH_SOURCE-derived root would drop
# the file into the submodule's own tree and the app would still not start.
#
# There is deliberately NO version argument. The pin is the point; a consumer
# that needs another version bumps versions.env, where the matching SHA lives.
set -euo pipefail

_SQLITE3_WASM_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../01-core" && pwd)"
# shellcheck source=../../01-core/load-versions-env.sh
source "${_SQLITE3_WASM_CORE}/load-versions-env.sh"
# shellcheck source=../../01-core/downloads.sh
source "${_SQLITE3_WASM_CORE}/downloads.sh"

setup_sqlite3_wasm() {
  local consumer_root="${1:?consumer repo root required}" out_dir out_file url
  if [ ! -d "${consumer_root}" ]; then
    printf 'setup-sqlite3-wasm.sh: consumer root not found: %s\n' "${consumer_root}" >&2
    return 1
  fi
  load_versions_env "${_SQLITE3_WASM_CORE}/versions.env"
  if [ -z "${SQLITE3_WASM_VERSION:-}" ] || [ -z "${SQLITE3_WASM_SHA256:-}" ]; then
    printf 'setup-sqlite3-wasm.sh: SQLITE3_WASM_VERSION/SQLITE3_WASM_SHA256 are not set in\n' >&2
    printf '                       %s/versions.env - the ContainerHub pin predates the key.\n' "${_SQLITE3_WASM_CORE}" >&2
    return 1
  fi
  out_dir="${consumer_root}/web"
  out_file="${out_dir}/sqlite3.wasm"
  url="https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${SQLITE3_WASM_VERSION}/sqlite3.wasm"
  mkdir -p "${out_dir}"
  printf 'sqlite3.wasm %s -> %s\n' "${SQLITE3_WASM_VERSION}" "${out_file}"
  download_verified_file "${url}" "${SQLITE3_WASM_SHA256}" "${out_file}"
  printf 'sqlite3.wasm verified (sha256 %s). flutter run -d chrome is now possible.\n' \
    "${SQLITE3_WASM_SHA256}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  setup_sqlite3_wasm "${1:-}"
fi
