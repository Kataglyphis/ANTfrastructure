#!/usr/bin/env bash
# setup-gstreamer.sh's debug-log switch under set -u with the knob unset; not covered: the log collection itself.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SETUP="${TESTS_DIR}/../03-media/build/gstreamer/common/setup-gstreamer.sh"

# From save_logs() through the top-level block that arms it, as the script runs them.
_block="$(sed -n '/^save_logs() {$/,/^  trap save_logs EXIT$/p' "${SETUP}")
fi"

t_case "the switch defaults to off where it is read, so an unset knob is not fatal"
_rc=0
_out="$(env -u GSTREAMER_DEBUG_LOGS LOG_DIR=/nonexistent bash -euo pipefail -c "${_block}"'
printf "armed=%s\n" "${GSTREAMER_DEBUG_LOGS}"' 2>&1)" || _rc=$?
t_assert_eq "0" "${_rc}" "${_out}"
t_assert_contains "${_out}" "armed=false"

t_case "the switch still arms the log trap when set"
_dir="$(mktemp -d)"
_rc=0
_out="$(GSTREAMER_DEBUG_LOGS=true LOG_DIR="${_dir}/logs" bash -euo pipefail -c "${_block}"'
trap -p EXIT' 2>&1)" || _rc=$?
t_assert_eq "0" "${_rc}" "${_out}"
t_assert_contains "${_out}" "save_logs"
t_assert_ok test -d "${_dir}/logs"
rm -rf "${_dir}"

t_summary
