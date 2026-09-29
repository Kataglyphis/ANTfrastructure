#!/usr/bin/env bash
# Deletes a compiler-cache key's entries that older runs saved on this ref, so the key keeps
# one entry. GitHub's own clean-up evicts the least recently used entry of the whole
# repository once it passes its quota, whatever key that entry serves, so the entries one
# key leaves behind would push out another key's only one. A newer run's entry stays, and so
# does every other ref's. Never fails the job: without `actions: write` it warns.
#
# Called by compiler-cache-prune and, before it saves, by compiler-cache-save.
# In: CACHE_KEY, GH_TOKEN, RUN_ID, RUN_ATTEMPT, GITHUB_REPOSITORY, GITHUB_REF, GITHUB_OUTPUT,
# and REQUIRE_SAVED=1 to delete only once this run's own entry exists (a job after the save:
# a build that never saved must not leave the key empty).
set -euo pipefail

prefix="compiler-cache-${CACHE_KEY}-"
pruned=0
if ! entries="$(gh api -X GET "repos/${GITHUB_REPOSITORY}/actions/caches" -f key="${prefix}" -f ref="${GITHUB_REF}" \
    -f per_page=100 --paginate --jq '.actions_caches[] | "\(.id) \(.key)"')"; then
  echo "::warning::could not list the ${prefix}* cache entries; deleting none (does the job grant actions: write?)"
  echo "pruned=0" >> "${GITHUB_OUTPUT}"
  exit 0
fi
current="${prefix}${RUN_ID}-${RUN_ATTEMPT}"
if [[ "${REQUIRE_SAVED:-0}" == 1 ]] && ! awk -v k="${current}" '$2 == k { found = 1 } END { exit !found }' <<< "${entries}"; then
  echo "::warning::this run saved no ${current}; keeping the older entries"
  echo "pruned=0" >> "${GITHUB_OUTPUT}"
  exit 0
fi
while read -r id key; do
  [[ -n "${id}" ]] || continue
  # The exact key and a run-attempt suffix: key 'x64' must not reach 'x64-gcc'.
  [[ "${key#"${prefix}"}" =~ ^([0-9]+)-([0-9]+)$ ]] || continue
  run="${BASH_REMATCH[1]}"
  attempt="${BASH_REMATCH[2]}"
  if (( run < RUN_ID || (run == RUN_ID && attempt < RUN_ATTEMPT) )); then
    if gh api -X DELETE "repos/${GITHUB_REPOSITORY}/actions/caches/${id}" > /dev/null; then
      echo "deleted ${key}"
      pruned=$((pruned + 1))
    else
      echo "::warning::could not delete ${key} (does the job grant actions: write?)"
    fi
  fi
done <<< "${entries}"
echo "pruned=${pruned}" >> "${GITHUB_OUTPUT}"
