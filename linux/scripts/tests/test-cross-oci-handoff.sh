#!/usr/bin/env bash
# Tests for the --no-push OCI-layout stage handoff (refactoring backlog C,
# 2026-08-30): cross-stage-build.sh + the build-cross-chain.sh guard.
#
# WHY THIS SUITE EXISTS
# ---------------------
# Multi-stage --no-push chains were REFUSED because BuildKit's OCI worker
# resolves FROM against the registry. The handoff fixes it: every locally-built
# stage is exported to an OCI layout and handed to the child as
#   --build-context <parent-tag>=oci-layout://<dir>
# and android additionally lands in the runtime lane's artifact dir. These
# tests pin the three behaviors that would silently regress to the 2026-08-08
# stale-parent bug if someone removed or reordered the wiring:
#   * push=0 with a built parent context → --build-context appended
#   * push=0 without the context → no --build-context (registry fallback)
#   * push=1 → never a --build-context
#   * the chain guard allows a FULL no-push chain but still refuses mid-chain
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CSB="${TESTS_DIR}/../01-core/cross-stage-build.sh"
CHAIN="$(dirname "${CSB}")/../build-cross-chain.sh"

# Extract the functions under test; everything they call is stubbed.
eval "$(sed -n '/^_cross_stage_run_resolve_parent() {/,/^}/p' "${CSB}")"
eval "$(sed -n '/^cross_local_handoff_enabled() {/,/^}/p' "${CSB}")"
eval "$(sed -n '/^cross_stage_context_dir() {/,/^}/p' "${CSB}")"
eval "$(sed -n '/^cross_ensure_local_context_workdir() {/,/^}/p' "${CSB}")"
eval "$(sed -n '/^_chain_no_push_guard() {/,/^}/p' "${CHAIN}")"

log() { :; }
warn() { :; }
is_dry_run() { return 1; }
export_image_to_oci_layout() { return 0; }
cross_stage_resolve_parent_pin() { printf '%s' "reg.io/img:cross-parent-amd64@sha256:test"; }
cross_stage_tag() { printf '%s' "reg.io/img:cross-parent-amd64"; }

export CROSS_CONTEXT_ROOT="${TMPDIR:-/tmp}/cross-oci-test.$$"
export CROSS_CONTEXT_WORKDIR=""
export CROSS_LOCAL_CONTEXT_HANDOFF=1
trap 'rm -rf "${CROSS_CONTEXT_ROOT}"' EXIT

case_context_present() {
  export CROSS_NO_PUSH=1
  cross_stage_context_dir() { printf '%s' "${CROSS_CONTEXT_ROOT}/parent-amd64"; }
  mkdir -p "${CROSS_CONTEXT_ROOT}/parent-amd64"
  printf '{"schemaVersion":2,"manifests":[]}\n' > "${CROSS_CONTEXT_ROOT}/parent-amd64/index.json"
  out=()
  _cross_stage_run_resolve_parent out "child" "amd64" 0 "parent"
  t_assert_eq "1" "$( printf '%s\n' "${out[@]}" | grep -c -- '--build-context' || true )"
  t_assert_eq "reg.io/img:cross-parent-amd64=oci-layout://${CROSS_CONTEXT_ROOT}/parent-amd64" \
    "$( printf '%s\n' "${out[@]}" | grep -A1 '^--build-context$' | tail -1 )"
  t_assert_eq "4" "${#out[@]}"   # --build-arg BASE_IMAGE + --build-context (2 words)
}

case_context_missing() {
  export CROSS_NO_PUSH=1
  cross_stage_context_dir() { printf '%s' "${CROSS_CONTEXT_ROOT}/parent-amd64-missing"; }
  out=()
  _cross_stage_run_resolve_parent out "child" "amd64" 0 "parent"
  t_assert_eq "0" "$( printf '%s\n' "${out[@]}" | grep -c -- '--build-context' || true )"
  t_assert_eq "2" "${#out[@]}"
  t_assert_eq "--build-arg" "${out[0]}"
  t_assert_eq "BASE_IMAGE=reg.io/img:cross-parent-amd64" "${out[1]}"
}

case_push_never_context() {
  export CROSS_NO_PUSH=0
  out=()
  _cross_stage_run_resolve_parent out "child" "amd64" 1 "parent"
  t_assert_eq "0" "$( printf '%s\n' "${out[@]}" | grep -c -- '--build-context' || true )"
}

case_base_no_parent() {
  out=()
  _cross_stage_run_resolve_parent out "base" "" 0 ""
  t_assert_eq "0" "${#out[@]}"
}

case_workdir_idempotent() {
  export CROSS_NO_PUSH=1 CROSS_CONTEXT_WORKDIR=""
  d1=""
  cross_ensure_local_context_workdir >/dev/null 2>&1 || true
  d1="${CROSS_CONTEXT_WORKDIR}"
  d2=""
  cross_ensure_local_context_workdir >/dev/null 2>&1 || true
  d2="${CROSS_CONTEXT_WORKDIR}"
  [ -n "${d1}" ] || { t_assert_eq "nonempty" "empty (d1)"; return; }
  [ -n "${d2}" ] || { t_assert_eq "nonempty" "empty (d2)"; return; }
  t_assert_eq "${d1}" "${d2}"   # idempotent within one process
  case "${d1}" in
    ${CROSS_CONTEXT_ROOT}/cross-flow.*) t_assert_eq ok ok ;;
    *) t_assert_eq "wrong root: ${d1}" "cross-flow.*" ;;
  esac
}

case_guard_full_chain_allowed() {
  unset CROSS_NO_PUSH_FORCE 2>/dev/null || true
  export CROSS_NO_PUSH=1 CROSS_LOCAL_CONTEXT_HANDOFF=1
  FROM_STAGE_IDX=0 TO_STAGE_IDX=6
  _last_err=""
  _chain_no_push_guard
  t_assert_eq "" "${_last_err}"
}

case_guard_mid_chain_refused() {
  unset CROSS_NO_PUSH_FORCE 2>/dev/null || true
  export CROSS_NO_PUSH=1 CROSS_LOCAL_CONTEXT_HANDOFF=1
  FROM_STAGE_IDX=2 TO_STAGE_IDX=6
  _last_err=""
  _chain_no_push_guard
  case "${_last_err}" in
    *unsafe*) t_assert_eq refused refused ;;
    *) t_assert_eq "guard did not refuse: ${_last_err}" refused ;;
  esac
}

case_guard_force_escapes() {
  export CROSS_NO_PUSH=1 CROSS_LOCAL_CONTEXT_HANDOFF=1 CROSS_NO_PUSH_FORCE=1
  FROM_STAGE_IDX=2 TO_STAGE_IDX=6
  _last_err=""
  _chain_no_push_guard
  t_assert_eq "" "${_last_err}"
}

case_guard_handoff_disabled_refuses() {
  unset CROSS_NO_PUSH_FORCE 2>/dev/null || true
  export CROSS_NO_PUSH=1 CROSS_LOCAL_CONTEXT_HANDOFF=0
  FROM_STAGE_IDX=0 TO_STAGE_IDX=6
  _last_err=""
  _chain_no_push_guard
  case "${_last_err}" in
    *unsafe*) t_assert_eq refused refused ;;
    *) t_assert_eq "guard did not refuse: ${_last_err}" refused ;;
  esac
}

# err() used by the guard RECORDS instead of exiting (cases assert on _last_err).
err() { _last_err="$*"; return 42; }

t_case "push=0 with a built parent context → --build-context appended";  case_context_present
t_case "push=0 without the parent context → registry fallback, no --build-context"; case_context_missing
t_case "push=1 → never a --build-context"; case_push_never_context
t_case "base (no parent) → no build args"; case_base_no_parent
t_case "context workdir minted fresh under CROSS_CONTEXT_ROOT, idempotent"; case_workdir_idempotent
t_case "guard: full no-push chain allowed with the handoff live"; case_guard_full_chain_allowed
t_case "guard: mid-chain no-push still refused"; case_guard_mid_chain_refused
t_case "guard: CROSS_NO_PUSH_FORCE still escapes the refusal"; case_guard_force_escapes
t_case "guard: handoff disabled → full-chain no-push refused (old behavior)"; case_guard_handoff_disabled_refuses


# The production callers reach cross_stage_context_dir through $(...), so an
# assignment inside it never escapes. Before 2026-09-01 this suite called
# cross_ensure_local_context_workdir DIRECTLY and was green while the handoff
# never activated in a real chain. Pin the subshell shape.
t_case "a workdir minted inside \$(...) does NOT reach the caller"
export CROSS_NO_PUSH=1
CROSS_CONTEXT_WORKDIR=""
# cross_local_handoff_enabled needs all three: the knob, the toggle, the exporter.
export CROSS_LOCAL_CONTEXT_HANDOFF=1
export_image_to_oci_layout() { :; }
_cross_sweep_orphaned_contexts() { :; }
# a previous case's root may be gone; mktemp -d under it would then fail
CROSS_CONTEXT_ROOT="$(mktemp -d)"
_probe() { cross_ensure_local_context_workdir >/dev/null 2>&1; printf '%s' "${CROSS_CONTEXT_WORKDIR:-}"; }
_inner="$( _probe )"
# t_assert_ok runs every argument as the command, so no message here.
t_assert_ok test -n "${_inner}"
t_assert_eq "" "${CROSS_CONTEXT_WORKDIR:-}" \
  "the parent must NOT — this is why the orchestrator has to mint it eagerly"

t_case "two \$(...) calls mint DIFFERENT workdirs (the production symptom)"
t_assert_ok test "$( _probe )" != "$( _probe )"

t_case "build-cross-chain.sh mints it eagerly in the orchestrator process"
t_assert_contains "$(cat "${TESTS_DIR}/../build-cross-chain.sh")" \
  "cross_local_handoff_enabled && cross_ensure_local_context_workdir" \
  "without this the --no-push handoff silently resolves FROM against the registry"

t_case "the android artifact dir never reads CROSS_CONTEXT_WORKDIR raw"
t_assert_eq "0" "$(grep -c -e 'CROSS_CONTEXT_WORKDIR}/android-artifacts' \
  "${TESTS_DIR}/../01-core/cross-stage-build.sh")" \
  "a raw read aborts the android stage under set -u"

t_summary
