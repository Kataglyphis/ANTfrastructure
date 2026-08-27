#!/usr/bin/env bash
# ==============================================================================
# ghcr-delete-tags.sh — delete NAMED legacy tags from the GHCR package.
#
# WHY THIS EXISTS (2026-08-27)
# ---------------------------
# ghcr-prune-package.sh deletes UNTAGGED versions. It deliberately keeps every
# tagged one, because a tag is a promise someone may be relying on. That leaves
# the other half of the mess untouched: tags that are provably dead — written by
# a naming scheme the chain abandoned, or pointing at an index whose children
# are already gone.
#
# Deleting a tag on GHCR means deleting the VERSION that carries it, and a
# version can carry SEVERAL tags and be a CHILD of a kept index. Deleting the
# wrong one silently breaks a tag nobody asked about. Hence the safety model.
#
# SAFETY MODEL (fail-closed at every step)
#   * The tag list is EXPLICIT — passed as args or --from-file. There is no
#     globbing and no heuristic: this script never decides what is legacy.
#   * KEEP-set = every tag NOT on the delete list, resolved live against the
#     registry, PLUS every digest those tags reference as index children.
#   * A candidate version is SKIPPED when
#       - its digest is in the KEEP-set (shared with a kept tag or child), or
#       - it carries any tag that is not on the delete list, or
#       - it is younger than KEEP_DAYS (guards a push in flight).
#   * If a KEEP tag's own manifest cannot be read, the script ABORTS: an
#     incomplete keep-set must never reach the delete loop.
#   * Default is a DRY RUN. GHCR_DELETE_TAGS_CONFIRM=1 actually deletes.
#
# KNOBS
#   GHCR_PKG / GHCR_OWNER            as in ghcr-prune-package.sh
#   KEEP_DAYS                        age guard in days (default 2)
#   GHCR_TOKEN                       PAT override (default: docker login)
#   GHCR_DELETE_TAGS_CONFIRM=1       actually delete
#
# Usage:
#   bash linux/host-config/ghcr-delete-tags.sh --from-file tags.txt
#   bash linux/host-config/ghcr-delete-tags.sh old-tag-a old-tag-b
# ==============================================================================
set -uo pipefail

_GHCR_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=linux/host-config/ghcr-common.sh
. "${_GHCR_SH_DIR}/ghcr-common.sh"

KEEP_DAYS="${KEEP_DAYS:-2}"
CONFIRM="${GHCR_DELETE_TAGS_CONFIRM:-0}"

log() { printf '[ghcr-del] %s\n' "$*"; }
err() { printf '[ghcr-del] ERROR: %s\n' "$*" >&2; exit 1; }

DELETE_TAGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-file) [ -r "${2:-}" ] || err "cannot read ${2:-<none>}"
                 while read -r _t; do [ -n "${_t}" ] && DELETE_TAGS+=("${_t}"); done < "$2"; shift 2 ;;
    -*)          err "unknown flag $1" ;;
    *)           DELETE_TAGS+=("$1"); shift ;;
  esac
done
[ "${#DELETE_TAGS[@]}" -gt 0 ] || err "no tags given — this script never guesses"

TOKEN="$(ghcr_pat)" || err "no ghcr credential (docker login ghcr.io, or set GHCR_TOKEN)"
[ -n "${TOKEN}" ] || err "empty ghcr token"

REG_TOKEN="$(ghcr_registry_token "${TOKEN}")" || err "registry token exchange failed"

export TOKEN REG_TOKEN GHCR_OWNER GHCR_PKG KEEP_DAYS CONFIRM GHCR_MANIFEST_ACCEPT
printf '%s\n' "${DELETE_TAGS[@]}" > /tmp/ghcr-del-list.$$
export DEL_FILE="/tmp/ghcr-del-list.$$"
trap 'rm -f "${DEL_FILE}"' EXIT

python3 - <<'PY'
import json, os, subprocess, sys, datetime
TOK=os.environ["TOKEN"]; RTOK=os.environ["REG_TOKEN"]
OWN=os.environ["GHCR_OWNER"]; PKG=os.environ["GHCR_PKG"]
KEEP_DAYS=int(os.environ["KEEP_DAYS"]); CONFIRM=os.environ["CONFIRM"]=="1"
ACC=os.environ["GHCR_MANIFEST_ACCEPT"]
delete_tags=set(l.strip() for l in open(os.environ["DEL_FILE"]) if l.strip())

def api(path, method="GET"):
    c=["curl","-fsS","-X",method,"-H",f"Authorization: Bearer {TOK}",
       "-H","Accept: application/vnd.github+json",f"https://api.github.com{path}"]
    r=subprocess.run(c,capture_output=True)
    return (r.returncode==0, r.stdout)

def reg(path, accept=ACC):
    r=subprocess.run(["curl","-fsSL","-H",f"Authorization: Bearer {RTOK}",
                      "-H",f"Accept: {accept}",f"https://ghcr.io/v2/{OWN}/{PKG}{path}"],
                     capture_output=True)
    return r.stdout if r.returncode==0 else b""

# ── inventory ────────────────────────────────────────────────────────────────
versions=[]; page=1
while True:
    ok,body=api(f"/users/{OWN}/packages/container/{PKG}/versions?per_page=100&page={page}")
    if not ok: sys.exit("[ghcr-del] ERROR: cannot list versions (token needs read:packages)")
    batch=json.loads(body)
    if not batch: break
    versions+=batch; page+=1
print(f"[ghcr-del]   {len(versions)} versions total")

all_tags=set()
for v in versions: all_tags |= set(v.get("metadata",{}).get("container",{}).get("tags",[]))
missing=delete_tags-all_tags
if missing: print(f"[ghcr-del]   note: {len(missing)} named tag(s) not present: {', '.join(sorted(missing))}")

keep_tags=sorted(all_tags-delete_tags)
print(f"[ghcr-del] resolving {len(keep_tags)} KEEP tag(s) for child digests…")
keep_digests=set(); unresolved=[]
for t in keep_tags:
    m=reg(f"/manifests/{t}")
    if not m: unresolved.append(t); continue
    try: d=json.loads(m)
    except Exception: unresolved.append(t); continue
    for k in d.get("manifests",[]): keep_digests.add(k["digest"])
if unresolved:
    sys.exit(f"[ghcr-del] ABORT: {len(unresolved)} kept tag(s) unreadable "
             f"({', '.join(unresolved[:6])}) — keep-set would be incomplete")
print(f"[ghcr-del]   keep-set: {len(keep_digests)} child digest(s) from kept indexes")

cutoff=(datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=KEEP_DAYS))
cands=[]; skipped=[]
for v in versions:
    tags=set(v.get("metadata",{}).get("container",{}).get("tags",[]))
    if not (tags & delete_tags): continue
    extra=tags-delete_tags
    if extra: skipped.append((v["name"][:19],f"also carries kept tag(s): {', '.join(sorted(extra))}")); continue
    if v["name"] in keep_digests:
        skipped.append((v["name"][:19],"referenced as a child of a kept index")); continue
    created=datetime.datetime.fromisoformat(v["created_at"].replace("Z","+00:00"))
    if created>cutoff:
        skipped.append((v["name"][:19],f"younger than KEEP_DAYS={KEEP_DAYS}")); continue
    cands.append((v["id"],v["name"],sorted(tags),v["created_at"]))

for dg,why in skipped: print(f"[ghcr-del]   SKIP {dg}  {why}")
print(f"[ghcr-del]   DELETE candidates: {len(cands)} version(s) carrying "
      f"{sum(len(c[2]) for c in cands)} tag(s)")
if not CONFIRM:
    print("[ghcr-del] DRY RUN (set GHCR_DELETE_TAGS_CONFIRM=1 to delete):")
    for _,dg,tags,created in cands:
        print(f"    would delete  {dg[:26]}  {created[:10]}  {', '.join(tags)}")
    sys.exit(0)

print(f"[ghcr-del] deleting {len(cands)} version(s)…")
done=fail=0
for vid,dg,tags,_ in cands:
    ok,_b=api(f"/users/{OWN}/packages/container/{PKG}/versions/{vid}","DELETE")
    if ok: done+=1
    else:  fail+=1; print(f"[ghcr-del]   FAILED {dg[:26]} ({', '.join(tags)})")
print(f"[ghcr-del] done: {done} deleted, {fail} failed, {len(skipped)} skipped.")
PY
