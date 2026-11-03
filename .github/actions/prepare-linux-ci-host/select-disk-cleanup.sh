#!/usr/bin/env bash
# select-disk-cleanup.sh <true|fast|false> <floor-gb> [path]: prints the cleanup to run; `fast` becomes `true` when the runner starts below the floor.
set -euo pipefail

mode="${1:?mode required}" floor="${2:?floor required}" path="${3:-/}"
case "${floor}" in ''|*[!0-9]*) printf '::error::fast-floor-gb must be a whole number, not %s\n' "${floor}" >&2; exit 1 ;; esac
if [ "${mode}" != fast ]; then
  printf '%s\n' "${mode}"
  exit 0
fi
# An unreadable disk is an error here: guessing would hide the very pull failure this floor exists for.
free_gb="$(df -BG --output=avail "${path}" | tail -n 1 | tr -dc '0-9')"
[ -n "${free_gb}" ] || { printf '::error::cannot read the free space of %s\n' "${path}" >&2; exit 1; }
if [ "${free_gb}" -lt "${floor}" ]; then
  printf '%sG free before the pull, under the %sG floor: running the full cleanup.\n' "${free_gb}" "${floor}" >&2
  printf 'true\n'
else
  printf '%sG free before the pull, floor %sG: the fast cleanup is enough.\n' "${free_gb}" "${floor}" >&2
  printf 'fast\n'
fi
