#!/usr/bin/env bash
# artifact-common.sh — aggregator entry point for the build scripts layer.
#
# Sources all 01-core modules in dependency order:
#   1. common.sh          (versions.env, logging, platform, ubuntu-mirror, downloads, parallelism)
#   2. tag-naming.sh      (cross-chain + runtime tag functions)
#   3. digest-pinning.sh  (registry digest resolution)
#   4. build-helpers.sh   (nerdctl wrappers, build-arg helpers)
#   5. context-management.sh (runtime context, OCI export, stage handoff)
#   6. version-forwarding.sh (auto-discovered --build-arg forwarding from versions.env)
#   7. cli-parsers.sh     (shared CLI argument parsing)
#   8. runtime-build-fns.sh (per-arch build chain functions)

_ARTIFACT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME_CONTEXT_ROOT="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/runtime-build-contexts}"

# Load common.sh (versions.env, platform.sh, logging.sh, ubuntu-mirror.sh,
# downloads.sh, parallelism.sh).  common.sh has its own _VERSIONS_ENV_LOADED
# guard so double-sourcing is safe.
# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/common.sh" ] && source "${_ARTIFACT_COMMON_DIR}/common.sh"

# canonical_target_arch() is provided by platform.sh (sourced above)

normalize_target_arches() {
  local raw_arches="$1"
  local result
  result="$(arch_list_csv_normalize "${raw_arches}")" || {
    printf '[ERROR] At least one valid target architecture is required (got: %s)\n' "${raw_arches}" >&2
    return 1
  }
  printf '%s' "${result}"
}

# Source focused modules in dependency order.
# shellcheck disable=SC1090,SC1091
for _module in \
  tag-naming.sh digest-pinning.sh build-helpers.sh context-management.sh \
  version-forwarding.sh cli-parsers.sh runtime-build-fns.sh; do
  if [ -f "${_ARTIFACT_COMMON_DIR}/${_module}" ]; then
    source "${_ARTIFACT_COMMON_DIR}/${_module}"
  fi
done
