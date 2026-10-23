#!/usr/bin/env bash
# --gates-only: the content gate, then the runtime smoke, each arch in turn; a red content gate stops before the smoke (no build, no push).
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SUBJECT="${TESTS_DIR}/../build-runtime-manifest.sh"

_fn="$(t_fn_src "${SUBJECT}" _manifest_gates_only)" || exit 1
_CALLS="$(mktemp)"
trap 'rm -f "${_CALLS}"' EXIT

# _gates: runs the function with the gate runner stubbed; FAIL_SCRIPT names a gate script that reports red.
_gates() {
  (
    set +e
    export TARGET_ARCHES=amd64,arm64 REPO_ROOT=/repo
    RUNTIME_IMAGE_SMOKE="${RUNTIME_IMAGE_SMOKE:-1}"
    eval "${_fn}"
    ensure_foreign_binfmt() { :; }
    _manifest_each_arch() {
      echo "$1 $(basename "$2")" >> "${_CALLS}"
      [ "$(basename "$2")" = "${FAIL_SCRIPT:-}" ] && return 1
      return 0
    }
    _manifest_gates_only
  )
}

t_case "both gates run, content gate first, each over the arches"
: > "${_CALLS}"; _gates; rc=$?
t_assert_eq "0" "${rc}"
t_assert_eq "Wrapper content gate verify-shipped-wrapper.sh
Runtime-image smoke smoke-runtime-image.sh" "$(cat "${_CALLS}")"

t_case "RUNTIME_IMAGE_SMOKE=0 runs only the content gate"
: > "${_CALLS}"; RUNTIME_IMAGE_SMOKE=0 _gates
t_assert_eq "Wrapper content gate verify-shipped-wrapper.sh" "$(cat "${_CALLS}")"

t_case "a red content gate stops before the smoke and fails the run"
: > "${_CALLS}"; FAIL_SCRIPT=verify-shipped-wrapper.sh _gates; rc=$?
t_assert_eq "1" "${rc}"
t_assert_eq "Wrapper content gate verify-shipped-wrapper.sh" "$(cat "${_CALLS}")"

# Flag order must never turn a gate-only entry point into a publication path.
# shellcheck disable=SC2034 # The extracted production main reads these fixture globals.
_entry() (
  eval "$(t_fn_src "${SUBJECT}" _manifest_extra_arg)"
  eval "$(t_fn_src "${SUBJECT}" _manifest_exit_after_gates_if_requested)"
  eval "$(t_fn_src "${SUBJECT}" main)"
  eval "$(t_fn_src "${TESTS_DIR}/../01-core/runtime-flow-common.sh" runtime_prepare_flow)"
  GATES_ONLY=0 BUILD_IMAGES=1 CREATE_MANIFEST=1 PUSH_MANIFEST=0 PUSH_IMAGES=0 DRY_RUN=0
  IMAGE_NAME=ghcr.io/kataglyphis/example:latest REPO_ROOT=/repo ARTIFACT_BUILD_MODE=image
  TARGET_ARCHES=amd64 CROSS_VCS_REF=fixture CROSS_BUILD_DATE=fixture CROSS_RUN_ID=fixture
  run_runtime_arg_loop() {
    shift 2
    while [ "$#" -gt 0 ]; do
      _manifest_extra_arg "$@" || return 1
      shift "${_OARG_SHIFT}"
    done
  }
  runtime_post_parse_setup() { :; }
  runtime_wheels_setup() { :; }
  hailo_validate_knobs() { :; }
  runtime_host_payload_arches() { :; }
  runtime_resolve_app_ref() { :; }
  _manifest_gates_only() { echo GATES; return "${FAIL_GATES:-0}"; }
  _manifest_build_and_smoke() { echo BUILD; }
  create_manifest() { echo PUBLISH; }
  _manifest_check_freshness() { :; }
  log() { :; }
  err() { printf '%s\n' "$*" >&2; exit 1; }
  main "$@"
)

t_case "gates-only exits before build or publication regardless of push flag order"
for _flag in --push --push-all --push-manifest --manifest-only; do
  _out="$(_entry --gates-only "${_flag}")"; _rc=$?
  t_assert_eq 0 "${_rc}"
  t_assert_eq GATES "${_out}"
  _out="$(_entry "${_flag}" --gates-only)"; _rc=$?
  t_assert_eq 0 "${_rc}"
  t_assert_eq GATES "${_out}"
done

t_case "a failed gates-only entry point cannot continue to publication"
_out="$(FAIL_GATES=1 _entry --push --gates-only)"; _rc=$?
t_assert_eq 1 "${_rc}"
t_assert_eq GATES "${_out}"

t_case "ordinary runs still reach the build and publication after the gates-only helper"
_out="$(_entry --push-all)"; _rc=$?
t_assert_eq 0 "${_rc}"
t_assert_eq $'BUILD\nPUBLISH' "${_out}"

t_summary
