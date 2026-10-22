#!/usr/bin/env bash
# The wrapper-build timer stops before the smoke gate wait, so a gate that outlasts the build does not read as build time.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
RBF="${TESTS_DIR}/../01-core/runtime-build-fns.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
_LOG="${_work}/log"
: > "${_LOG}"

_FNS=""
for _fn in runtime_build_wrapper_image _runtime_wrapper_then_ship _runtime_ship_image _runtime_timed _runtime_heartbeat; do
  _FNS+="$(t_fn_src "${RBF}" "${_fn}")"$'\n' || exit 1
done
eval "${_FNS}"

# The build takes 1 s, the gate wait 3 s: the build's timer must read 1 or 2, never 4.
log() { echo "$*" >> "${_LOG}"; }
warn() { echo "$*" >> "${_LOG}"; }
is_dry_run() { return 1; }
runtime_pushes_wrapper_images() { return 1; }
_runtime_build_wrapper() { local -n _t=$2; _t="repo:latest-$1"; sleep 1; }
_runtime_smoke_wait() { sleep 3; return 0; }
_runtime_push_wrapper_tag() { :; }

t_case "the wrapper-build timer reads the build, not the gate wait"
runtime_build_wrapper_image amd64
line="$(grep 'step=wrapper-build' "${_LOG}")"
t_assert_contains "${line}" "[runtime-timing] arch=amd64 step=wrapper-build"
secs="${line##*secs=}"; secs="${secs%% *}"
t_assert_eq "1" "$([ "${secs}" -ge 1 ] && [ "${secs}" -le 2 ] && echo 1 || echo 0)"

t_summary
