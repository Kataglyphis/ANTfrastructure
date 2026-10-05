#!/usr/bin/env bash
# host-config/prune-safe.sh: the keep target counts what the filter cannot free, and surplus cache-mount records go only on request.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
PRUNE_SAFE="${TESTS_DIR}/../../host-config/prune-safe.sh"

t_skip_unless "jq" command -v jq

_ps="$(mktemp -d)"
trap 'rm -rf "${_ps}"' EXIT
mkdir -p "${_ps}/bin"
export BUILDCTL_LOG="${_ps}/buildctl.log" PS_STORE="${_ps}/store.json"

# A stub store: `du` filters the JSON by type, `prune --filter id==X,...` deletes X, a type==regular prune deletes idle layers.
cat > "${_ps}/bin/buildctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${BUILDCTL_LOG}"
case "$1" in
  du)
    t=""; [ "${2:-}" = "--filter" ] && t="${3#type==}"
    jq --arg t "${t}" '[.[] | select($t == "" or (.recordType // "regular") == $t)]' "${PS_STORE}" ;;
  prune)
    f="${3:-}"
    case "${f}" in
      id==*) id="${f#id==}"; id="${id%%,*}"
             jq --arg id "${id}" '[.[] | select(.id != $id)]' "${PS_STORE}" > "${PS_STORE}.new" ;;
      type==regular) jq '[.[] | select((.recordType // "regular") != "regular" or .inUse)]' "${PS_STORE}" > "${PS_STORE}.new" ;;
      *) jq '[]' "${PS_STORE}" > "${PS_STORE}.new" ;;
    esac
    mv "${PS_STORE}.new" "${PS_STORE}" ;;
esac
exit 0
STUB
chmod +x "${_ps}/bin/buildctl"
PATH="${_ps}/bin:${PATH}"

# 150 GB of cache mounts (one id twice), 2 GB of local sources, 1 GB shared (not counted), 120 GB of layers.
_store() {
  local in_use="${1:-false}"
  jq -n --argjson u "${in_use}" '[
    {id:"aaa", recordType:"exec.cachemount", size:100000000000, shared:false, inUse:false, description:"cached mount /var/cache/sccache from exec x with id \"/sccache-amd64\""},
    {id:"zzz", recordType:"exec.cachemount", size:40000000000,  shared:false, inUse:false, description:"cached mount /var/cache/sccache from exec y with id \"/sccache-amd64\""},
    {id:"mmm", recordType:"exec.cachemount", size:10000000000,  shared:false, inUse:false, description:"cached mount /var/cache/ccache from exec z with id \"/ccache-amd64\""},
    {id:"src", recordType:"source.local",    size:2000000000,   shared:false, inUse:false, description:"local source"},
    {id:"shr", recordType:"exec.cachemount", size:1000000000,   shared:true,  inUse:false, description:"cached mount /tmp from exec w with id \"/shared\""},
    {id:"l1",  recordType:"regular",         size:60000000000,  shared:false, inUse:$u,    description:"layer"},
    {id:"l2",  size:60000000000, shared:false, inUse:false, description:"layer without a type"}
  ]' > "${PS_STORE}"
  : > "${BUILDCTL_LOG}"
}

t_case "the keep target adds the records a type==regular prune can never free"
_store
PRUNE_KEEP_GB=100 bash "${PRUNE_SAFE}" > "${_ps}/o.txt" 2>&1
t_assert_eq "0" "$?" "a clean run exits 0"
# 150 GB mounts + 2 GB sources = 152000 MB on top of 100 GB; the shared record and the layers do not count.
t_assert_contains "$(cat "${BUILDCTL_LOG}")" "prune --filter type==regular --keep-storage 252000" \
  "--keep-storage bounds the WHOLE store: a bare 100000 against 150 GB of cache mounts empties the layer cache"
t_assert_contains "$(cat "${_ps}/o.txt")" "100 GB of layer cache + 152000 MB the filter cannot free"

t_case "only the layer cache is a candidate unless surplus removal is asked for"
t_assert_eq "0" "$(grep -c -e '^prune --filter id==' "${BUILDCTL_LOG}" || true)" "no cache-mount record may be pruned by default"
t_assert_eq "1" "$(grep -c -e '^prune ' "${BUILDCTL_LOG}" || true)" "exactly one prune ran"
t_assert_contains "$(cat "${_ps}/o.txt")" "OK: all 4 cache-mount records survived"

t_case "a cache id with two records is reported, keeping the lowest record id"
t_assert_contains "$(cat "${_ps}/o.txt")" "/sccache-amd64" "the duplicate id must be named"
t_assert_contains "$(cat "${_ps}/o.txt")" "keeps aaa, surplus zzz" \
  "BuildKit reuses the lowest record id it can lock (bolt index order); the other is the surplus"

t_case "PRUNE_DUP_CACHEMOUNTS=1 removes exactly the surplus record, and the count check expects it"
_store
PRUNE_DUP_CACHEMOUNTS=1 bash "${PRUNE_SAFE}" > "${_ps}/o.txt" 2>&1
t_assert_eq "0" "$?" "removing a requested surplus record is not a lost cache"
t_assert_contains "$(cat "${BUILDCTL_LOG}")" "prune --filter id==zzz,type==exec.cachemount"
t_assert_eq "0" "$(grep -c -e 'id==aaa' "${BUILDCTL_LOG}" || true)" "the record BuildKit reuses must survive"
t_assert_eq "0" "$(grep -c -e 'id==mmm' "${BUILDCTL_LOG}" || true)" "a cache id with one record is never a duplicate"
t_assert_contains "$(cat "${_ps}/o.txt")" "1 surplus duplicate(s) removed on request"

t_case "surplus removal refuses while a build holds records"
_store true
PRUNE_DUP_CACHEMOUNTS=1 bash "${PRUNE_SAFE}" > "${_ps}/o.txt" 2>&1
t_assert_eq "1" "$?" "a running build may fall back to the surplus record"
t_assert_contains "$(cat "${_ps}/o.txt")" "REFUSED"
t_assert_eq "0" "$(grep -c -e '^prune' "${BUILDCTL_LOG}" || true)" "a refusal must prune nothing"

t_case "DRY_RUN names the commands and touches nothing"
_store
DRY_RUN=1 PRUNE_KEEP_GB=100 PRUNE_DUP_CACHEMOUNTS=1 bash "${PRUNE_SAFE}" > "${_ps}/o.txt" 2>&1
t_assert_eq "0" "$(grep -c -e '^prune' "${BUILDCTL_LOG}" || true)"
t_assert_contains "$(cat "${_ps}/o.txt")" "would run: buildctl prune --filter id==zzz,type==exec.cachemount"
t_assert_contains "$(cat "${_ps}/o.txt")" "would run: buildctl prune --filter type==regular --keep-storage 252000"

t_case "a garbage keep value is refused before anything runs"
_store
PRUNE_KEEP_GB=12G bash "${PRUNE_SAFE}" > "${_ps}/o.txt" 2>&1
t_assert_eq "2" "$?"
t_assert_eq "" "$(cat "${BUILDCTL_LOG}")" "buildctl must not be reached"

t_summary
