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
    TARGET_ARCHES=amd64,arm64 REPO_ROOT=/repo RUNTIME_IMAGE_SMOKE="${RUNTIME_IMAGE_SMOKE:-1}"
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

t_summary
