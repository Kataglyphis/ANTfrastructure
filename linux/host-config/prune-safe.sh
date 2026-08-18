#!/usr/bin/env bash
# prune-safe.sh — reclaim buildkit disk WITHOUT destroying compile caches
# (backlog CACHE1, 2026-08-17).
#
# THE INCIDENT THIS PREVENTS: `nerdctl builder prune -f` deletes EVERYTHING
# reclaimable in the buildkit store — including `type==exec.cachemount`
# records, which is where RUN --mount=type=cache lives: ccache, sccache,
# uv, pip, cargo, apt, llvm-src. On 2026-08-17 repeated disk-alarm prunes
# wiped the ccache mounts and both target-LLVM builds ran COLD (+~1.5-2h
# on the compiler stage). Measured store split at the time: 207 GB layer
# cache (`regular`, cheap to regenerate) vs 4.9 GB cache mounts (hours of
# compile time). The old command threw away the 4.9 GB to get the 207 GB.
#
# WHAT THIS DOES INSTEAD: prune ONLY `type==regular` records (layer cache)
# via buildctl's --filter — nerdctl builder prune has no such flag. Cache
# mounts, frontend and internal records are never candidates. Prints the
# cachemount inventory before/after so survival is PROVEN, not assumed.
#
# USAGE:
#   linux/host-config/prune-safe.sh              # reclaim ALL layer cache
#   PRUNE_KEEP_GB=100 linux/host-config/prune-safe.sh
#                                                # keep newest ~100 GB of it
#   DRY_RUN=1 linux/host-config/prune-safe.sh    # report only, prune nothing
#
# Mid-run safety: buildkit skips in-use records, so running this during a
# chain is safe for correctness — but later stages lose layer reuse and
# rebuild more. Fine in a disk emergency; prefer between-stage windows.
set -euo pipefail

export BUILDKIT_HOST="${BUILDKIT_HOST:-unix:///run/user/$(id -u)/buildkit/buildkitd.sock}"
PRUNE_KEEP_GB="${PRUNE_KEEP_GB:-0}"

command -v buildctl >/dev/null || { echo "FATAL: buildctl not found (this tool needs its --filter; nerdctl builder prune cannot do this)" >&2; exit 1; }

# Store breakdown by record type, unit-aware (du prints B/KB/MB/GB).
_du_by_type() {
  buildctl du -v 2>/dev/null | awk '
    /^Type:/{t=$2}
    /^Size:/{v=$2; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v)
      m=1; if(u=="KB")m=1024; else if(u=="MB")m=1048576; else if(u=="GB")m=1073741824
      sz[t]+=v*m; n[t]++}
    END{for(k in sz) printf "  %-18s %8.2f GB  (%d records)\n", k, sz[k]/1073741824, n[k]}'
}

_cachemounts() {
  buildctl du -v 2>/dev/null | awk '
    /^Type:/{t=$2} /^Description:/{d=substr($0,14)}
    /^Size:/{if(t=="exec.cachemount"){v=$2; u=v; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v)
      m=1; if(u=="KB")m=1024; else if(u=="MB")m=1048576; else if(u=="GB")m=1073741824
      printf "  %8.2f GB  %s\n", v*m/1073741824, substr(d,1,70)}}' | sort -rn
}

echo "=== prune-safe: buildkit store BEFORE ==="
_du_by_type
echo "--- cache mounts (MUST all survive) ---"
_cachemounts
n_before="$(buildctl du --filter type==exec.cachemount 2>/dev/null | grep -c . || true)"

if [ "${DRY_RUN:-0}" = "1" ]; then
  _keep=""; [ "${PRUNE_KEEP_GB}" != "0" ] && _keep=" --keep-storage $((PRUNE_KEEP_GB * 1000))"
  echo "DRY_RUN=1 — would run: buildctl prune --filter type==regular${_keep}"
  exit 0
fi

echo
echo "=== pruning type==regular (layer cache) only... ==="
if [ "${PRUNE_KEEP_GB}" != "0" ]; then
  buildctl prune --filter type==regular --keep-storage "$((PRUNE_KEEP_GB * 1000))" >/dev/null
else
  buildctl prune --filter type==regular >/dev/null
fi

echo "=== AFTER ==="
_du_by_type
echo "--- cache mounts ---"
_cachemounts
n_after="$(buildctl du --filter type==exec.cachemount 2>/dev/null | grep -c . || true)"

if [ "${n_after}" -lt "${n_before}" ]; then
  echo "WARNING: cachemount record count dropped ${n_before} -> ${n_after} — investigate!" >&2
  exit 1
fi
echo "OK: all ${n_after} cache-mount records survived."
