#!/usr/bin/env bash
# Tests for _runtime_run_package_smoke (LOG29): the wrapper-smoke gate that
# runs the Dockerfile.package `--target wrapper-smoke` stage between the package
# build and the wrapper build. Exercises the early-return paths and the build
# invocation, with all runtime helpers stubbed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="${TESTS_DIR}/../01-core"
source "${TESTS_DIR}/test-harness.sh"

# -- stubs ----------------------------------------------------------------
log()  { :; }
warn() { :; }

# retry/run used by runtime_push_tag (defined in the file); stub before sourcing.
retry() { shift 2; "$@"; }
run()   { "$@"; }

# Source the unit under test (it defines _runtime_run_package_smoke).
# Sourced first so its definitions are available, then overridden below.
PACKAGE_DOCKERFILE_PATH="${CORE_DIR}/../../Dockerfile.package"
NERDCTL_BIN=nerdctl
source "${CORE_DIR}/runtime-build-fns.sh"

# is_dry_run is a function from build-helpers.sh; stub it per-test.
DRY_RUN=0
is_dry_run() { [ "${DRY_RUN:-0}" = "1" ]; }

# Build-arg helpers — no-op (array name passed, must exist).
append_common_build_args()        { :; }
append_runtime_accelerator_build_args() { :; }

# Runtime resolution stubs — override the file's definitions.
runtime_android_pin()              { :; }
runtime_use_local_artifact_context() { return 1; }
runtime_artifact_image_ref()       { :; }
_runtime_resolve_parent_context()  { printf -v "$3" 'repo/base:dummy'; printf -v "$4" '.'; }
append_package_build_args()         { :; }
runtime_remove_stage_context()      { :; }

# Capture whether run_nerdctl_build was called and with what args.
RUN_NERDCTL_CALLED=0
RUN_NERDCTL_ARGS=()
run_nerdctl_build() {
  RUN_NERDCTL_CALLED=1
  RUN_NERDCTL_ARGS=("$@")
}

# -- tests ----------------------------------------------------------------

t_case "dry-run mode returns 0 without invoking a build"
DRY_RUN=1
RUN_NERDCTL_CALLED=0
_runtime_run_package_smoke amd64
t_assert_eq "0" "$?"
t_assert_eq "0" "${RUN_NERDCTL_CALLED}" "run_nerdctl_build should NOT be called in dry-run"
DRY_RUN=0

t_case "WRAPPER_SMOKE_GATE=0 returns 0 without invoking a build"
WRAPPER_SMOKE_GATE=0
RUN_NERDCTL_CALLED=0
_runtime_run_package_smoke amd64
t_assert_eq "0" "$?"
t_assert_eq "0" "${RUN_NERDCTL_CALLED}" "run_nerdctl_build should NOT be called when WRAPPER_SMOKE_GATE=0"
unset WRAPPER_SMOKE_GATE

t_case "default (gate on) invokes run_nerdctl_build with --target wrapper-smoke"
RUN_NERDCTL_CALLED=0
RUN_NERDCTL_ARGS=()
_runtime_run_package_smoke amd64
t_assert_eq "0" "$?"
t_assert_eq "1" "${RUN_NERDCTL_CALLED}" "run_nerdctl_build SHOULD be called by default"
# Check that --target wrapper-smoke is in the args.
_target_found=0
for _a in "${RUN_NERDCTL_ARGS[@]}"; do
  [ "$_a" = "--target" ] && _target_found=1
  if [ "$_target_found" = "1" ] && [ "$_a" = "wrapper-smoke" ]; then
    _target_found=2
    break
  fi
done
t_assert_eq "2" "${_target_found}" "--target wrapper-smoke must be in the build args"

t_case "build failure propagates (run_nerdctl_build returns 1)"
run_nerdctl_build() { return 1; }
_runtime_run_package_smoke amd64
t_assert_eq "1" "$?" "wrapper-smoke gate failure must propagate"
# restore
run_nerdctl_build() { RUN_NERDCTL_CALLED=1; RUN_NERDCTL_ARGS=("$@"); return 0; }

t_summary
