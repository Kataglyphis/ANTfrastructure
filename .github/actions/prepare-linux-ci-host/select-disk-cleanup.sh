#!/usr/bin/env bash
# select-disk-cleanup.sh <true|fast|false> <fast-floor-gb> <min-free-gb> [path]: prints the cleanup to run, or refuses a runner no cleanup can make fit.
set -euo pipefail

mode="${1:?mode required}" floor="${2:?fast floor required}" min_free="${3:?minimum free required}" path="${4:-/}"
for value in "${floor}" "${min_free}"; do
  case "${value}" in ''|*[!0-9]*) printf '::error::fast-floor-gb and min-free-gb must be whole numbers, not %s\n' "${value}" >&2; exit 1 ;; esac
done
# An unreadable disk is an error here: guessing would hide the very pull failure these floors exist for.
free_gb="$(df -BG --output=avail "${path}" | tail -n 1 | tr -dc '0-9')"
[ -n "${free_gb}" ] || { printf '::error::cannot read the free space of %s\n' "${path}" >&2; exit 1; }
# retry-disk-refusal reads this exact title; a job that failed any other way never re-runs.
if [ "${free_gb}" -lt "${min_free}" ]; then
  printf '::error title=runner-disk-refusal::%sG free on this runner, floor %sG (min-free-gb): refusing before the image pull\n' "${free_gb}" "${min_free}" >&2
  exit 3
fi
if [ "${mode}" != fast ]; then
  printf '%s\n' "${mode}"
elif [ "${free_gb}" -lt "${floor}" ]; then
  printf '%sG free before the pull, under the %sG floor: running the full cleanup.\n' "${free_gb}" "${floor}" >&2
  printf 'true\n'
else
  printf '%sG free before the pull, floor %sG: the fast cleanup is enough.\n' "${free_gb}" "${floor}" >&2
  printf 'fast\n'
fi
