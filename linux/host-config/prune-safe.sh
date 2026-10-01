#!/usr/bin/env bash
# Prunes layer cache only, never cachemounts ([PRUNE_KEEP_GB=N] [DRY_RUN=1] [PRUNE_DUP_CACHEMOUNTS=1]): docs/linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches
set -euo pipefail

export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/user/$(id -u)/buildkit/buildkitd.sock}"
PRUNE_KEEP_GB="${PRUNE_KEEP_GB:-0}"
case "${PRUNE_KEEP_GB}" in ''|*[!0-9]*) echo "FATAL: PRUNE_KEEP_GB must be a whole number of GB, got '${PRUNE_KEEP_GB}'" >&2; exit 2 ;; esac

command -v buildctl >/dev/null || { echo "FATAL: buildctl not found (this tool needs its --filter; nerdctl builder prune cannot do this)" >&2; exit 1; }
command -v jq >/dev/null || { echo "FATAL: jq not found (the store is read as JSON: sizes, record types, in-use flags)" >&2; exit 1; }

# shellcheck source=SCRIPTDIR/../scripts/01-core/disk-guard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/01-core/disk-guard.sh"

_du_json() { local j; j="$(_disk_guard_du_json "$@")"; printf '%s\n' "${j:-[]}"; }

_du_by_type() {
  _du_json | jq -r 'group_by(.recordType // "regular") | .[]
    | "  \((.[0].recordType // "regular") + "                  " | .[0:18]) \(([.[].size] | add) / 1e9 * 100 | floor / 100) GB  (\(length) records)"'
}

_cachemounts() {
  _du_json --filter type==exec.cachemount | jq -r 'sort_by(-.size) | .[]
    | "  \(.size / 1e9 * 100 | floor / 100) GB  \(.description[0:70])"'
}

_cachemount_count() { _du_json --filter type==exec.cachemount | jq 'length'; }

echo "=== prune-safe: buildkit store BEFORE ==="
_du_by_type
echo "--- cache mounts (MUST all survive) ---"
_cachemounts
n_before="$(_cachemount_count)"

dups="$(_disk_guard_cachemount_duplicates)"
if [ -n "${dups}" ]; then
  echo "--- cache ids with surplus records (BuildKit reuses the first; the rest are dead weight) ---"
  printf '%s\n' "${dups}" | awk -F'\t' '{printf "  %-24s keeps %s, surplus %s  %.2f GB%s\n", $1, $2, $3, $4/1e9, ($5=="true" ? "  (IN USE)" : "")}'
fi

in_use="$(_du_json --filter type==regular | jq '[.[] | select(.inUse)] | length')"
if [ "${in_use}" -gt 0 ]; then
  echo "NOTE: ${in_use} layer record(s) are in use by a running build; they survive any keep value, and an in-use cache mount reports 0 B, so the keep target below is a floor." >&2
fi

keep_args=()
if [ "${PRUNE_KEEP_GB}" != "0" ]; then
  keep_mb="$(_disk_guard_regular_keep_mb "${PRUNE_KEEP_GB}")"
  keep_args=(--keep-storage "${keep_mb}")
  echo "keep: ${PRUNE_KEEP_GB} GB of layer cache + $(( keep_mb - PRUNE_KEEP_GB * 1000 )) MB the filter cannot free (--keep-storage bounds the whole store) = ${keep_mb} MB"
fi

# Surplus duplicates go only on request and only with the store idle: an in-use record is not surplus.
dup_ids=()
if [ "${PRUNE_DUP_CACHEMOUNTS:-0}" = "1" ] && [ -n "${dups}" ]; then
  if [ "${in_use}" -gt 0 ] || [ -n "$(printf '%s\n' "${dups}" | awk -F'\t' '$5=="true"')" ]; then
    echo "REFUSED: PRUNE_DUP_CACHEMOUNTS=1 needs an idle store (a build holds records); rerun when no build runs." >&2
    exit 1
  fi
  mapfile -t dup_ids < <(printf '%s\n' "${dups}" | cut -f3)
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  for id in "${dup_ids[@]}"; do echo "DRY_RUN=1 — would run: buildctl prune --filter id==${id},type==exec.cachemount"; done
  echo "DRY_RUN=1 — would run: buildctl prune --filter type==regular${keep_args[*]:+ ${keep_args[*]}}"
  exit 0
fi

for id in "${dup_ids[@]}"; do
  echo "=== removing surplus cache-mount record ${id} ==="
  buildctl prune --filter "id==${id},type==exec.cachemount" >/dev/null
done

echo
echo "=== pruning type==regular (layer cache) only... ==="
buildctl prune --filter type==regular "${keep_args[@]}" >/dev/null

echo "=== AFTER ==="
_du_by_type
echo "--- cache mounts ---"
_cachemounts
n_after="$(_cachemount_count)"
n_expected=$(( n_before - ${#dup_ids[@]} ))

if [ "${n_after}" -lt "${n_expected}" ]; then
  echo "WARNING: cachemount record count dropped ${n_before} -> ${n_after} (expected ${n_expected}) — investigate!" >&2
  exit 1
fi
echo "OK: all ${n_after} cache-mount records survived${dup_ids[0]:+ (${#dup_ids[@]} surplus duplicate(s) removed on request)}."
