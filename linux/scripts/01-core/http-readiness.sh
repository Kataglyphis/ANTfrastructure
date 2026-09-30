#!/usr/bin/env bash
# Returns instead of exiting, so callers can dump logs first. docs/shared-script-libraries.md#01-corehttp-readinesssh

[ -n "${_HTTP_READINESS_SH_LOADED:-}" ] && return 0
_HTTP_READINESS_SH_LOADED=1

# wait_for_http <url> <who> [attempts=50] [sleep=0.2]: silent while starting, prints only the verdict.
wait_for_http() {
  local url="${1:?wait_for_http: a url is required}"
  local who="${2:-the server}"
  local attempts="${3:-50}"
  local nap="${4:-0.2}"
  local i

  for ((i = 0; i < attempts; i++)); do
    if curl -fs -o /dev/null "${url}"; then
      return 0
    fi
    sleep "${nap}"
  done

  printf '%s never served %s within %s attempt(s) at %ss.\n' \
    "${who}" "${url}" "${attempts}" "${nap}" >&2
  return 1
}
