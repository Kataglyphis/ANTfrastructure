#!/usr/bin/env bash
# setup-gstreamer.sh's top-level knob defaults under set -u with the knobs unset; not covered: the log collection or the wrappers' own work.
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

t_case "the C++ cargo wrapper runs first with the toolchain dir unset"
_defaults="$(grep -E '^: "\$\{GSTREAMER_[A-Z_]+:=' "${SETUP}")"
_wrapper="$(sed -n '/^prepare_cargo_host_cxx_wrapper() {$/,/^}$/p' "${SETUP}")"
_rc=0
_out="$(env -u GSTREAMER_CARGO_HOST_TOOLCHAIN_DIR bash -euo pipefail -c "${_defaults}
prepare_host_compiler_wrapper() { printf 'dir=%s\\n' \"\$3\"; }
${_wrapper}
prepare_cargo_host_cxx_wrapper g++" 2>&1)" || _rc=$?
t_assert_eq "0" "${_rc}" "${_out}"
t_assert_contains "${_out}" "dir=/tmp/gstreamer-cargo-host-toolchain"

t_summary
