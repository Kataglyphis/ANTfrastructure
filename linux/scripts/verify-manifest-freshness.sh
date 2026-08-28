#!/usr/bin/env bash
# verify-manifest-freshness.sh — does :latest-cross index the bytes THIS run built?
# Registry-only: no pull, no emulation. Why both assertions are needed, and why
# neither suffices alone: docs/cross-build-verification.md.
#
# Usage: linux/scripts/verify-manifest-freshness.sh [--repo OWNER/PKG] [--tag latest-cross]
# Env:   EXPECT_RUN_ID  assert the shared run-id equals this exact value
#        STALE_RISCV64 / STALE_ARM64 / STALE_AMD64
#                       assert the child digest is NOT this known-previous digest
# Exit:  0 all assertions hold, 1 otherwise.
set -uo pipefail

REPO="kataglyphis/kataglyphis_beschleuniger"
TAG="latest-cross"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tag)  TAG="$2";  shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ok=0; fail=0
pass() { printf '  \033[0;32mOK\033[0m    %s\n' "$*"; ok=$((ok+1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }

TOK="$(curl -sf "https://ghcr.io/token?scope=repository:${REPO}:pull&service=ghcr.io" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])' 2>/dev/null)"
[ -n "${TOK}" ] || { printf 'could not obtain a registry token for %s\n' "${REPO}" >&2; exit 1; }
export TOK REPO TAG

printf '[manifest-freshness] %s:%s\n' "${REPO}" "${TAG}"
python3 - <<'PY'
import json, os, subprocess, sys
TOK=os.environ["TOK"]; REPO=os.environ["REPO"]; TAG=os.environ["TAG"]
ACC=("application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,"
     "application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json")
def reg(path, accept=ACC, head=False):
    c=["curl","-sfL","-H",f"Authorization: Bearer {TOK}","-H",f"Accept: {accept}"]
    if head: c += ["-o","/dev/null","-D","-"]
    c.append(f"https://ghcr.io/v2/{REPO}{path}")
    r=subprocess.run(c,capture_output=True)
    return r.stdout if r.returncode==0 else b""

idx=reg(f"/manifests/{TAG}")
if not idx: print(f"  FAIL  {TAG} does not resolve"); sys.exit(1)
d=json.loads(idx)
kids=[m for m in d.get("manifests",[]) if m.get("platform",{}).get("os")!="unknown"]
if not kids: print(f"  FAIL  {TAG} is not a multi-arch index"); sys.exit(1)

fails=0; runids={}
for m in kids:
    arch=m["platform"]["architecture"]; dig=m["digest"]
    # (1) the per-arch tag must resolve to this exact digest
    hdr=reg(f"/manifests/{TAG}-{arch}", head=True).decode("utf-8","replace")
    tagdig=""
    for line in hdr.splitlines():
        if line.lower().startswith("docker-content-digest:"):
            tagdig=line.split(":",1)[1].strip()
    if not tagdig:
        print(f"  FAIL  {arch}: tag {TAG}-{arch} does not resolve"); fails+=1
    elif tagdig!=dig:
        print(f"  FAIL  {arch}: index says {dig[:19]} but {TAG}-{arch} is {tagdig[:19]}"); fails+=1
    else:
        print(f"  OK    {arch}: index child matches {TAG}-{arch} ({dig[:19]})")
    # a digest we were told is stale must not appear
    stale=os.environ.get(f"STALE_{arch.upper()}")
    if stale:
        if dig.startswith(stale) or stale.startswith(dig):
            print(f"  FAIL  {arch}: index child IS the known-stale digest {stale[:19]}"); fails+=1
        else:
            print(f"  OK    {arch}: differs from the known-stale {stale[:19]}")
    # (2) provenance label
    man=reg(f"/manifests/{dig}")
    try:
        cfg=json.loads(man)["config"]["digest"]
        labels=json.loads(reg(f"/blobs/{cfg}","*/*")).get("config",{}).get("Labels") or {}
        runids[arch]=labels.get("org.kataglyphis.run-id")
    except Exception:
        runids[arch]=None

uniq={v for v in runids.values() if v}
if None in runids.values() or not uniq:
    print(f"  FAIL  run-id label missing on: {[a for a,v in runids.items() if not v]}"); fails+=1
elif len(uniq)!=1:
    print(f"  FAIL  children disagree on run-id: {runids}"); fails+=1
else:
    rid=uniq.pop()
    exp=os.environ.get("EXPECT_RUN_ID")
    if exp and rid!=exp:
        print(f"  FAIL  run-id is {rid}, expected {exp}"); fails+=1
    else:
        print(f"  OK    all {len(kids)} children share run-id {rid}")

print(f"[manifest-freshness] {'PASS' if fails==0 else str(fails)+' FAILURE(S)'}")
sys.exit(1 if fails else 0)
PY
