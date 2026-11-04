#!/usr/bin/env bash
# Re-runs one job of RUN_ID that carries the runner-disk-refusal annotation; GitHub refuses a second job re-run while the first is active, and that attempt's completion calls this again.
set -euo pipefail

: "${REPO:?}" "${RUN_ID:?}" "${RUN_ATTEMPT:?}" "${MAX_ATTEMPTS:?}"
failed="$(gh api --paginate "repos/${REPO}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}/jobs" \
  --jq '.jobs[] | select(.conclusion == "failure") | "\(.id) \(.name)"')"
refused=""
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  titles="$(gh api --paginate "repos/${REPO}/check-runs/${line%% *}/annotations" --jq '.[].title')"
  if grep -qxF -e 'runner-disk-refusal' <<<"${titles}"; then
    refused="${line}"
    break
  fi
done <<<"${failed}"

if [ -z "${refused}" ]; then
  printf 'run %s attempt %s: no job was refused for disk; nothing to re-run\n' "${RUN_ID}" "${RUN_ATTEMPT}"
  exit 0
fi
if [ "${RUN_ATTEMPT}" -ge "${MAX_ATTEMPTS}" ]; then
  printf '::warning::run %s stays red: job %s was refused for disk on attempt %s, the last allowed\n' "${RUN_ID}" "${refused#* }" "${RUN_ATTEMPT}"
  exit 0
fi
# The one-job endpoint, never rerun-failed-jobs, which would also re-run a genuine failure beside it.
gh api -X POST "repos/${REPO}/actions/jobs/${refused%% *}/rerun" >/dev/null
printf 'run %s: re-running job %s, refused for disk on attempt %s\n' "${RUN_ID}" "${refused#* }" "${RUN_ATTEMPT}"
