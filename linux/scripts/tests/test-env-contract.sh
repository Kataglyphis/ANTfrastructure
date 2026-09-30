#!/usr/bin/env bash
# Every override runtime_shared_usage_env_overrides documents must be consumed somewhere in the runtime lane.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
RBF="${CORE}/runtime-build-fns.sh"

# Documented-but-dead names with a pending fix; the self-retiring guard fails once one is consumed.
KNOWN_DEAD=()

t_case "runtime-build-fns.sh exists and parses"
t_assert_ok test -f "${RBF}"
t_assert_ok bash -n "${RBF}"

# Documented names: ALL-CAPS first tokens inside the usage-overrides heredoc.
_doc_vars="$(awk '/runtime_shared_usage_env_overrides\(\)/,/^}/' "${RBF}" \
  | grep -oE '^  [A-Z][A-Z0-9_]+' | tr -d ' ' | sort -u)"

t_case "usage-overrides block found and non-trivial"
t_assert_ok test "$(printf '%s\n' "${_doc_vars}" | wc -l)" -ge 5

# Wide on purpose: siblings legitimately consume overrides, so only a name referenced nowhere is a defect.
_surface="$(mktemp)"
{
  awk '/runtime_shared_usage_env_overrides\(\)/,/^}/ {next} {print}' "${RBF}"
  for f in "${CORE}"/*.sh; do
    [ "${f}" = "${RBF}" ] && continue
    cat "${f}"
  done
  cat "${TESTS_DIR}/../build-runtime-artifacts.sh" 2>/dev/null || true
  cat "${TESTS_DIR}/../build-runtime-manifest.sh" 2>/dev/null || true
  cat "${TESTS_DIR}/../build-cross-chain.sh" 2>/dev/null || true
  cat "${TESTS_DIR}/../lib-runtime-wheels.sh"   # consumes RUNTIME_WHEELS_SOURCE
} > "${_surface}"

_dead="" _zombie=""
while IFS= read -r v; do
  [ -n "${v}" ] || continue
  if grep -qE "(\\\$\{?${v}\b|--build-arg \"?${v}=)" "${_surface}"; then
    # live — must NOT be on the KNOWN_DEAD list
    for k in "${KNOWN_DEAD[@]}"; do
      [ "${k}" = "${v}" ] && _zombie="${_zombie} ${v}"
    done
  else
    _listed=0
    for k in "${KNOWN_DEAD[@]}"; do [ "${k}" = "${v}" ] && _listed=1; done
    [ "${_listed}" = "1" ] || _dead="${_dead} ${v}"
  fi
done <<< "${_doc_vars}"
rm -f "${_surface}"

t_case "no NEW documented-but-unconsumed env override (the XC4 class)"
t_assert_eq "" "${_dead}" "documented in usage-overrides but referenced NOWHERE in the runtime lane:${_dead:+ }${_dead} — wire it or delete the doc line"

t_case "KNOWN_DEAD entries are still dead (self-retiring guard)"
t_assert_eq "" "${_zombie}" "now CONSUMED but still on KNOWN_DEAD — XC4 fixed? remove from this list:${_zombie:+ }${_zombie}"

t_summary
