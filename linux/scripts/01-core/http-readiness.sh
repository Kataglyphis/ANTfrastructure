#!/usr/bin/env bash
# http-readiness.sh - wait for an HTTP endpoint to answer, or say it never did.
#
# Three consumers had written the same poll loop, and the differences between
# them were all accidents: how many attempts, how long a sleep, and -- the one
# that matters -- whether failing KILLS the caller. It must not: the nginx
# caller needs to dump `docker logs` before it dies, and a helper that calls
# `exit` takes that away. So this RETURNS non-zero and says what it waited for.
#
# docs/shared-script-libraries.md#01-corehttp-readinesssh
#
# Sets no -e/-u/-o pipefail: sourcing must not change the caller's shell options.

[ -n "${_HTTP_READINESS_SH_LOADED:-}" ] && return 0
_HTTP_READINESS_SH_LOADED=1

# wait_for_http <url> <who> [attempts] [sleep_seconds] -> 0 when it answers.
#
# `who` names the thing being waited for in the failure message; a bare URL
# never told anyone which server failed to come up. Defaults are 50 attempts at
# 0.2s, i.e. ten seconds, which is what the consumers had converged on.
#
# Probes that fail while a server is starting are the EXPECTED case and are
# silent. Only the verdict is printed.
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
