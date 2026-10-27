#!/usr/bin/env bash
# The cerbero fetch-only retry against a stub uv; not covered: which upstream pages trip a checksum.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SRC="${TESTS_DIR}/../03-media/build/gstreamer/android/build-android-from-source.sh"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT

# _retry <failures before success>: the calls the retry made and its status.
_retry() {
  : > "${W}/calls"
  FAILS="$1" CALLS="${W}/calls" bash -c "$(t_fn_src "${SRC}" cerbero_fetch_package_retry)"'
    CONFIG_NAME=android CERBERO_JOBS_ARGS=(--jobs 4)
    sleep() { printf "sleep %s\n" "$1" >> "${CALLS}"; }
    uv() {
      printf "uv %s\n" "$*" >> "${CALLS}"
      [ "$(grep -c "^uv" "${CALLS}")" -gt "${FAILS}" ]
    }
    cerbero_fetch_package_retry; printf "rc=%s\n" "$?" >> "${CALLS}"' >/dev/null 2>&1
  cat "${W}/calls"
}

t_case "one failed fetch is retried, and only fetch-package runs"
_out="$(_retry 1)"
t_assert_eq "2" "$(grep -c '^uv run ./cerbero-uninstalled -c android.cbc --jobs 4 fetch-package gstreamer-1.0$' <<<"${_out}")"
t_assert_contains "${_out}" "sleep 30"
t_assert_contains "${_out}" "rc=0"

t_case "three failed fetches fail the build, with no sleep after the last"
_out="$(_retry 5)"
t_assert_eq "3" "$(grep -c '^uv ' <<<"${_out}")"
t_assert_eq "2" "$(grep -c '^sleep ' <<<"${_out}")"
t_assert_contains "${_out}" "rc=1"

t_case "the build fetches through the retry before it packages"
t_assert_contains "$(cat "${SRC}")" "cerbero_fetch_package_retry || exit 1

    echo \"==> Building GStreamer...\""

t_summary
