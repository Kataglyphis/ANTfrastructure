#!/usr/bin/env bash
# Aggregator: sources common.sh and the host-side 01-core modules in dependency order.

_ARTIFACT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME_CONTEXT_ROOT="${RUNTIME_CONTEXT_ROOT:-${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/opencode/runtime-build-contexts}"
NERDCTL_BIN="${NERDCTL_BIN:-nerdctl}"

# shellcheck disable=SC1091
[ -f "${_ARTIFACT_COMMON_DIR}/common.sh" ] && source "${_ARTIFACT_COMMON_DIR}/common.sh"

normalize_target_arches() {
  local raw_arches="$1"
  local result
  result="$(arch_list_csv_normalize "${raw_arches}")" || {
    printf '[ERROR] At least one valid target architecture is required (got: %s)\n' "${raw_arches}" >&2
    return 1
  }
  printf '%s' "${result}"
}

# resolve_arch_list [fallback]: TARGET_ARCHES, TARGET_ARCH, ARCHITECTURES, then the fallback.
resolve_arch_list() {
  local fallback="${1:-${CROSS_DEFAULT_ARCHES:-amd64,arm64,riscv64}}"
  local raw="${TARGET_ARCHES:-${TARGET_ARCH:-${ARCHITECTURES:-${fallback}}}}"
  normalize_target_arches "${raw}"
}

# No abseil-headers.sh: it has no host-side caller, and its in-image consumers source_module it.
# shellcheck disable=SC1090,SC1091
_ac_module=""
for _ac_module in \
  tag-naming.sh stage-defs.sh digest-pinning.sh chain-verify.sh ancestry.sh \
  build-helpers.sh cross-stage-build.sh \
  context-management.sh version-forwarding.sh cli-parsers.sh \
  runtime-build-fns.sh compiler-resolution.sh parallel-loop.sh \
  path-helpers.sh; do
  if [ -f "${_ARTIFACT_COMMON_DIR}/${_ac_module}" ]; then
    source "${_ARTIFACT_COMMON_DIR}/${_ac_module}"
  fi
done
unset _ac_module
