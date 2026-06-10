#!/usr/bin/env bash
# artifact-common.sh — aggregator entry point for the build scripts layer.
#
# Sources all 01-core modules in dependency order:
#   1. common.sh              (versions.env, logging, platform, ubuntu-mirror, downloads, parallelism)
#   2. tag-naming.sh          (cross-chain + runtime tag functions)
#   3. stage-defs.sh          (declarative cross-lane stage graph)
#   4. digest-pinning.sh      (registry digest resolution)
#   5. build-helpers.sh       (nerdctl wrappers, build-arg helpers)
#   6. cross-stage-build.sh   (cross-stage build orchestration: build, push, pin)
#   7. context-management.sh  (runtime context, OCI export, stage handoff)
#   8. version-forwarding.sh  (auto-discovered --build-arg forwarding)
#   9. cli-parsers.sh         (shared CLI argument parsing)
#  10. runtime-build-fns.sh   (per-arch build chain functions)
#  11. compiler-resolution.sh (host compiler resolution for media builds)
#  12. parallel-loop.sh       (per-architecture parallel build loop)

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
#   tag-naming.sh         — cross-chain + runtime tag functions
#   stage-defs.sh          — declarative cross-lane stage graph
#   digest-pinning.sh      — registry manifest digest resolution
#   build-helpers.sh       — nerdctl wrappers, build-arg helpers
#   cross-stage-build.sh   — shared cross-stage build + pin orchestration
#   context-management.sh  — runtime context, OCI export, stage handoff
#   version-forwarding.sh  — auto-discovered --build-arg forwarding
#   cli-parsers.sh         — shared CLI argument parsing
#   runtime-build-fns.sh   — per-arch runtime build chain functions
#   compiler-resolution.sh — host compiler resolution for media builds
#   parallel-loop.sh       — per-architecture parallel build loop
# shellcheck disable=SC1090,SC1091
for _module in \
  tag-naming.sh stage-defs.sh digest-pinning.sh build-helpers.sh \
  cross-stage-build.sh \
  context-management.sh version-forwarding.sh cli-parsers.sh \
  runtime-build-fns.sh compiler-resolution.sh parallel-loop.sh; do
  if [ -f "${_ARTIFACT_COMMON_DIR}/${_module}" ]; then
    source "${_ARTIFACT_COMMON_DIR}/${_module}"
  fi
done
