#!/usr/bin/env bash
# docker pull with retries; it records its exit code and duration, because pull-first runs it detached.
set -uo pipefail

image="$1"
attempts="$2"
timeout_s="$3"
state="$4"

start="$(date +%s)"
rc=1
for attempt in $(seq 1 "${attempts}"); do
  echo "Attempt ${attempt}/${attempts}: docker pull ${image}"
  # The timeout bounds a hung pull so the retry actually happens.
  if timeout "${timeout_s}" docker pull "${image}"; then
    echo "Pulled ${image}"
    rc=0
    break
  fi
  if [ "${attempt}" -lt "${attempts}" ]; then
    echo "Pull failed; retrying in 30s"
    sleep 30
  fi
done
[ "${rc}" -eq 0 ] || echo "::error::Failed to pull ${image} after ${attempts} attempts"
echo "$(( $(date +%s) - start ))" > "${state}.seconds"
# Written last: the waiter takes its existence as the end of the pull.
echo "${rc}" > "${state}.rc.tmp" && mv "${state}.rc.tmp" "${state}.rc"
exit "${rc}"
