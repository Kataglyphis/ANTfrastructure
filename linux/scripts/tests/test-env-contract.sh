#!/usr/bin/env bash
# Env-override contract for the runtime lane (backlog 2026-08-11 XC4 class).
#
# runtime_shared_usage_env_overrides DOCUMENTS operator env overrides; nothing
# machine-checked that a documented name is actually CONSUMED. XC4 found the
# live instance (since wired): ONNX_PACKAGE / PYTORCH_EXTRA were advertised,
# forwarded by nothing, and Dockerfile.torch baked fixed values — the documented
# GPU path silently built a CPU venv, and smoke-torch-venv validates the BAKED
# env so it could not catch it. Contract enforced here: every ALL-CAPS name in the
# usage-overrides block must be referenced OUTSIDE that block somewhere in the
# runtime lane (forwarded as a build-arg or consumed host-side).
#
# KNOWN_DEAD carries any open documented-but-dead names so the suite ships
# green while a fix is pending; a guard fails the suite the moment an entry
# becomes live without being removed here (the Windows PinParity [pend]
# pattern).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CORE="${TESTS_DIR}/../01-core"
RBF="${CORE}/runtime-build-fns.sh"

# backlog XC4 CLOSED 2026-08-12: ONNX_PACKAGE / PYTORCH_EXTRA are now forwarded
# by append_wrapper_build_args and consumed as ARGs in Dockerfile.torch; the
# dead TORCH_DOCKERFILE_PATH doc line was removed (the torch build consumes
# WRAPPER_DOCKERFILE_PATH). Add new entries here only WITH a pending fix.
KNOWN_DEAD=()

t_case "runtime-build-fns.sh exists and parses"
t_assert_ok test -f "${RBF}"
t_assert_ok bash -n "${RBF}"

# Documented names: ALL-CAPS first tokens inside the usage-overrides heredoc.
_doc_vars="$(awk '/runtime_shared_usage_env_overrides\(\)/,/^}/' "${RBF}" \
  | grep -oE '^  [A-Z][A-Z0-9_]+' | tr -d ' ' | sort -u)"

t_case "usage-overrides block found and non-trivial"
t_assert_ok test "$(printf '%s\n' "${_doc_vars}" | wc -l)" -ge 5

# Consumption surface: ALL of 01-core + the runtime entry scripts, minus the
# usage heredoc itself. Wide on purpose — overrides are legitimately consumed
# by siblings (cross-stage-build forwards the mirror/accelerator vars into the
# helper invocation, context-management consumes RUNTIME_CONTEXT_ROOT, …);
# only a name referenced NOWHERE is the XC4 defect.
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
