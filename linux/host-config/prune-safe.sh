#!/usr/bin/env bash
# Prunes layer cache only, never cachemounts ([PRUNE_KEEP_GB=N] [DRY_RUN=1]): docs/linux-host-setup.md#b7-reclaiming-disk-without-losing-the-compile-caches
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
