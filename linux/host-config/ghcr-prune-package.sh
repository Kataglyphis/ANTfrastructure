#!/usr/bin/env bash
# ==============================================================================
# ghcr-prune-package.sh — delete STALE ghcr package versions, safely.
#
# WHY THIS EXISTS (2026-08-24): the kataglyphis_beschleuniger container package
# holds 771 versions. Almost all are UNTAGGED digests left behind every time a
# moving tag (latest-cross, cross-media-<arch>, …) is re-pushed. They are dead
# weight — but a naive "delete everything untagged" is a REGISTRY-CORRUPTING
# move, twice over:
#
#   1. The per-arch entries of a multi-arch manifest LIST are themselves
#      untagged manifests. Delete them and every `nerdctl pull latest-cross`
#      dies with MANIFEST_UNKNOWN while the index still looks fine.
#   2. A build that is pushing RIGHT NOW creates untagged manifests seconds
#      before it tags them. Deleting young digests races the chain's own push
#      (this repo builds for hours at a time — the race is not hypothetical).
#
# SAFETY MODEL (fail-closed at every step):
#   KEEP  = every tagged version
#         + every digest referenced as a CHILD by any kept manifest index
#           (resolved live against the registry, per tag)
#         + every version younger than KEEP_DAYS (push-in-flight guard)
#   DELETE candidates = everything else — and even then only with
#   GHCR_PRUNE_CONFIRM=1; the default run is a DRY RUN that prints the plan.
#   If ANY tag's manifest cannot be resolved, the script ABORTS: an unreadable
#   tag means the keep-set may be incomplete, and an incomplete keep-set must
#   never reach the delete loop.
#
# KNOBS
#   GHCR_PKG              package name        (default kataglyphis_beschleuniger)
#   GHCR_OWNER            registry namespace  (default kataglyphis)
#   KEEP_DAYS             age guard in days   (default 7 — build sagas span days)
#   GHCR_PRUNE_CONFIRM=1  actually delete     (default: dry run)
#   GHCR_TOKEN            PAT override        (default: ghcr auth from
#                                              ~/.docker/config.json; needs
#                                              read:packages + delete:packages)
#
# The PAT is read from the local docker login and sent ONLY to api.github.com /
# ghcr.io — the two hosts it was issued for.
# ==============================================================================
set -euo pipefail

_GHCR_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/host-config/ghcr-common.sh
. "${_GHCR_SH_DIR}/ghcr-common.sh"

KEEP_DAYS="${KEEP_DAYS:-7}"
CONFIRM="${GHCR_PRUNE_CONFIRM:-0}"
API="${GHCR_API}"

log()  { printf '[ghcr-prune] %s\n' "$*"; }
err()  { printf '[ghcr-prune] ERROR: %s\n' "$*" >&2; exit 1; }

# ── auth (shared: ghcr-common.sh) ─────────────
TOKEN="$(ghcr_pat)" || err "no ghcr credential (docker login ghcr.io, or set GHCR_TOKEN)"
[ -n "${TOKEN}" ] || err "empty ghcr token"

_api() { curl -fsS -H "Authorization: Bearer ${TOKEN}" \
              -H "Accept: application/vnd.github+json" "$@"; }

REG_TOKEN="$(ghcr_registry_token "${TOKEN}")" || err "registry token exchange failed"

# ── 1) inventory: every package version ──────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log "listing versions of ${GHCR_PKG} (this pages through all of them)…"
: > "${WORK}/versions.tsv"    # id <TAB> digest <TAB> created_at <TAB> tags-csv
page=1
while :; do
  resp="$(_api "${API}/user/packages/container/${GHCR_PKG}/versions?per_page=100&page=${page}")" \
    || err "version listing failed on page ${page} (needs read:packages)"
  n="$(printf '%s' "${resp}" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"
  [ "${n}" -eq 0 ] && break
  printf '%s' "${resp}" | python3 -c '
import sys, json
for v in json.load(sys.stdin):
    tags = ",".join(v.get("metadata", {}).get("container", {}).get("tags", []))
    print("%s\t%s\t%s\t%s" % (v["id"], v["name"], v["created_at"], tags))' >> "${WORK}/versions.tsv"
  page=$((page + 1))
done
TOTAL="$(wc -l < "${WORK}/versions.tsv")"
[ "${TOTAL}" -gt 0 ] || err "no versions found — wrong package name?"
log "  ${TOTAL} versions total"

# ── 2) keep-set: tags + their index children ─────────────────────────────────
# Every tagged digest is kept, and every tag's manifest is fetched; when it is
# an index, its child digests are kept too. A fetch failure ABORTS (fail-closed).
: > "${WORK}/keep.digests"
awk -F'\t' '$4 != "" {print $2}' "${WORK}/versions.tsv" >> "${WORK}/keep.digests"
mapfile -t ALL_TAGS < <(awk -F'\t' '$4 != "" {print $4}' "${WORK}/versions.tsv" | tr ',' '\n' | sort -u)
# Fail-CLOSED on a collapsed tag view (adversarial review 2026-08-24): the
# packages API's tag field is read best-effort, so an API shape change would
# silently yield ZERO tags — and an empty keep-set turns the delete loop into
# a registry wipe. This package always carries dozens of tags; below MIN_TAGS
# something is wrong with the INVENTORY, not the registry.
MIN_TAGS="${MIN_TAGS:-10}"
[ "${#ALL_TAGS[@]}" -ge "${MIN_TAGS}" ] \
  || err "only ${#ALL_TAGS[@]} tag(s) visible (MIN_TAGS=${MIN_TAGS}) — inventory looks broken, refusing"
log "resolving ${#ALL_TAGS[@]} tag(s) against the registry for child digests…"
ACCEPT="${GHCR_MANIFEST_ACCEPT}"
for tag in "${ALL_TAGS[@]}"; do
  m="$(curl -fsS -H "Authorization: Bearer ${REG_TOKEN}" -H "Accept: ${ACCEPT}" \
        "https://ghcr.io/v2/${GHCR_OWNER}/${GHCR_PKG}/manifests/${tag}")" \
    || err "cannot resolve tag '${tag}' — keep-set would be incomplete, refusing to continue"
  printf '%s' "${m}" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for entry in d.get("manifests", []):     # index children; plain manifests have none
    print(entry["digest"])' >> "${WORK}/keep.digests"
  # TOCTOU half (b): keep the digest the tag resolves to RIGHT NOW too — the
  # packages-API snapshot may lag a concurrent re-tag, and the moving tag can
  # land on an OLD digest (byte-identical re-push, manual rollback tag).
  curl -fsSI -H "Authorization: Bearer ${REG_TOKEN}" -H "Accept: ${ACCEPT}" \
      "https://ghcr.io/v2/${GHCR_OWNER}/${GHCR_PKG}/manifests/${tag}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' \
    >> "${WORK}/keep.digests"
done
sort -u "${WORK}/keep.digests" -o "${WORK}/keep.digests"
# Phantom check (review finding): 6 legacy tags in this registry are ALREADY
# dangling (their index children 404). Phantoms in the keep-set are harmless
# for deletion safety (superset filter) but pad the sanity gate — say so.
_phantoms="$(comm -23 "${WORK}/keep.digests" <(cut -f2 "${WORK}/versions.tsv" | sort -u) | wc -l)"
[ "${_phantoms}" -eq 0 ] || log "  note: ${_phantoms} kept digest(s) not in the inventory (children of already-dangling legacy tags — those tags are unpullable TODAY, independent of pruning)"
KEEPN="$(wc -l < "${WORK}/keep.digests")"
log "  keep-set: ${KEEPN} digest(s) (tagged + index children)"
[ "${KEEPN}" -ge "${#ALL_TAGS[@]}" ] || err "keep-set smaller than tag count — refusing"

# ── 3) candidates: untagged, unreferenced, and OLDER than KEEP_DAYS ──────────
CUTOFF="$(date -u -d "-${KEEP_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
python3 - "${WORK}" "${CUTOFF}" <<'PY'
import sys
work, cutoff = sys.argv[1], sys.argv[2]
keep = set(open(f"{work}/keep.digests").read().split())
cand, young, kept = [], 0, 0
for line in open(f"{work}/versions.tsv"):
    vid, digest, created, tags = line.rstrip("\n").split("\t")
    if digest in keep:
        kept += 1
    elif created >= cutoff:          # ISO-8601 zulu strings compare lexically
        young += 1
    else:
        cand.append((vid, digest, created))
with open(f"{work}/candidates.tsv", "w") as f:
    for vid, digest, created in cand:
        f.write(f"{vid}\t{digest}\t{created}\n")
print(f"[ghcr-prune]   kept (tagged/referenced): {kept}")
print(f"[ghcr-prune]   kept (younger than cutoff, push-in-flight guard): {young}")
print(f"[ghcr-prune]   DELETE candidates: {len(cand)}")
PY
sort -u "${WORK}/candidates.tsv" -o "${WORK}/candidates.tsv"   # pagination shift can duplicate rows
CANDN="$(wc -l < "${WORK}/candidates.tsv")"

# Sanity: never delete everything, and never more than 95% of the package in
# one run — a keep-set collapse (the gate-that-cannot-fail class) would
# otherwise sail straight into the delete loop.
[ "${CANDN}" -lt "${TOTAL}" ] || err "candidates == total — refusing"
[ "$(( CANDN * 100 ))" -le "$(( TOTAL * 95 ))" ] \
  || err "candidates ${CANDN}/${TOTAL} exceed 95% — keep-set looks broken, refusing"

# ── 4) dry run or delete ─────────────────────────────────────────────────────
if [ "${CONFIRM}" != "1" ]; then
  log "DRY RUN (set GHCR_PRUNE_CONFIRM=1 to delete). Oldest 10 candidates:"
  sort -t$'\t' -k3 "${WORK}/candidates.tsv" \
    | awk -F'\t' 'NR<=10 {printf "  would delete  %s  (%s)\n", substr($2,1,29), $3}'
  log "plan: delete ${CANDN} of ${TOTAL} versions; keep $((TOTAL - CANDN))."
  exit 0
fi

log "deleting ${CANDN} version(s)…"
DELETED=0; FAILED=0
SKIPPED=0
while IFS=$'\t' read -r vid digest created; do
  # TOCTOU half (a): a tag may have LANDED on this old digest since the
  # snapshot (rollback tag, byte-identical re-push). Re-read the version
  # immediately before deleting; any tag now => skip. Read failure => skip
  # too (fail-closed: never delete what we cannot re-verify).
  _now_tags="$(_api "${API}/user/packages/container/${GHCR_PKG}/versions/${vid}" 2>/dev/null \
    | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("metadata",{}).get("container",{}).get("tags",[])))' 2>/dev/null || echo x)"
  if [ "${_now_tags}" != "0" ]; then
    SKIPPED=$((SKIPPED + 1)); continue
  fi
  if _api -X DELETE \
       "${API}/user/packages/container/${GHCR_PKG}/versions/${vid}" >/dev/null 2>&1; then
    DELETED=$((DELETED + 1))
  else
    FAILED=$((FAILED + 1))
    log "  failed: ${digest} (id ${vid}) — continuing"
  fi
  # gentle pacing: stay far from secondary rate limits
  [ $(( (DELETED + FAILED) % 25 )) -eq 0 ] && sleep 2
done < "${WORK}/candidates.tsv"
log "done: ${DELETED} deleted, ${FAILED} failed, ${SKIPPED} skipped (tagged-or-unverifiable since snapshot), $((TOTAL - DELETED)) remain."
[ "${FAILED}" -eq 0 ] || exit 1
