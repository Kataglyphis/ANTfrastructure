#!/usr/bin/env bash
# push_retry_delay: one linear backoff for both push paths; no retry after the last attempt or a permanent error.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
CSB="${TESTS_DIR}/../01-core/cross-stage-build.sh"
_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
eval "$(t_fn_src "${CSB}" _cross_stage_push_error_is_transient)" || exit 1
eval "$(t_fn_src "${CSB}" push_retry_delay)" || exit 1
printf 'dial tcp: i/o timeout\n' > "${_work}/transient.log"
printf 'denied: requested access to the resource is denied\n' > "${_work}/permanent.log"

t_case "a transient error backs off linearly: attempt x base"
t_assert_eq "15" "$(push_retry_delay 1 4 15 "${_work}/transient.log")"
t_assert_eq "30" "$(push_retry_delay 2 4 15 "${_work}/transient.log")"
t_assert_eq "45" "$(push_retry_delay 3 4 15 "${_work}/transient.log")"

t_case "no retry after the last attempt"
t_assert_fails push_retry_delay 4 4 15 "${_work}/transient.log"

t_case "a permanent error is not retried"
t_assert_fails push_retry_delay 1 4 15 "${_work}/permanent.log"

t_case "an empty or unreadable log counts as transient, as the classifier defines it"
t_assert_eq "15" "$(push_retry_delay 1 4 15 "")"

t_summary
