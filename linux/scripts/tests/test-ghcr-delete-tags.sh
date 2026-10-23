#!/usr/bin/env bash
# Offline curl fixtures cover deletion plans and keep-set refusals; no registry request or real DELETE is allowed.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
source "${TESTS_DIR}/ghcr-registry-fixture.sh"
DELETE_SCRIPT="${1:-${TESTS_DIR}/../../host-config/ghcr-delete-tags.sh}"
PRUNE_SCRIPT="${2:-${TESTS_DIR}/../../host-config/ghcr-prune-package.sh}"
FIX="$(mktemp -d)"
trap 'rm -rf "${FIX}"' EXIT
mkdir -p "${FIX}/bin" "${FIX}/manifests"
cat > "${FIX}/bin/curl" <<'CURL'
#!/usr/bin/env bash
url=''; method=GET
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$FAKE_DIR/requests"
if [ "$method" != GET ]; then printf '%s\n' "$method" >> "$FAKE_DIR/forbidden-request"; exit 97; fi
case "$url" in
  *ghcr.io/token*) printf '%s\n' '{"token":"reg"}' ;;
  *'/versions?per_page=100&page=1') cat "$FAKE_DIR/versions.json" ;;
  *'/versions?'*) printf '%s\n' '[]' ;;
  */manifests/*) cat "$FAKE_DIR/manifests/${url##*/}.json" 2>/dev/null || exit 22 ;;
  *) exit 96 ;;
esac
CURL
chmod +x "${FIX}/bin/curl"
_ghcr_fixture_versions "${FIX}/versions.json" <<'VERSIONS'
1	sha256:index	2020-01-01T00:00:00Z	keep
2	sha256:child	2020-01-01T00:00:00Z	drop
3	sha256:shared	2020-01-01T00:00:00Z	drop,alias
4	sha256:old	2020-01-01T00:00:00Z	drop
5	sha256:young	2999-01-01T00:00:00Z	drop
6	sha256:untagged	2020-01-01T00:00:00Z	-
VERSIONS
printf '%s\n' '{"manifests":[{"digest":"sha256:child"}]}' > "${FIX}/manifests/keep.json"
printf '%s\n' '{"schemaVersion":2}' > "${FIX}/manifests/alias.json"
_delete_plan() {
  env FAKE_DIR="${FIX}" PATH="${FIX}/bin:${PATH}" GHCR_TOKEN=fixture GHCR_DELETE_TAGS_CONFIRM=0 KEEP_DAYS=2 \
    bash "${DELETE_SCRIPT}" "$@" 2>&1
}

t_case "only old requested versions outside the kept tags and index children are candidates"
out="$(_delete_plan drop missing)"; rc=$?
t_assert_eq 0 "${rc}"
t_assert_contains "${out}" '6 versions total'
t_assert_contains "${out}" 'named tag(s) not present: missing'
t_assert_contains "${out}" 'also carries kept tag(s): alias'
t_assert_contains "${out}" 'referenced as a child of a kept index'
t_assert_contains "${out}" 'younger than KEEP_DAYS=2'
t_assert_contains "${out}" 'DELETE candidates: 1 version(s) carrying 1 tag(s)'
t_assert_contains "${out}" 'would delete  sha256:old'
t_assert_fails test -e "${FIX}/forbidden-request"

t_case "an unreadable kept tag aborts before a deletion plan"
rm "${FIX}/manifests/keep.json"
out="$(_delete_plan drop)"; rc=$?
t_assert_eq 1 "${rc}"
t_assert_contains "${out}" 'ABORT: 1 kept tag(s) unreadable (keep)'
t_assert_fails grep -q 'DELETE candidates' <<< "${out}"
t_assert_fails test -e "${FIX}/forbidden-request"
t_case "both tools refuse a missing metadata companion before contacting a registry"
mkdir -p "${FIX}/without-helper"
install -m 0644 "${TESTS_DIR}/../../host-config/ghcr-common.sh" "${FIX}/without-helper/"
for tool in "${DELETE_SCRIPT}" "${PRUNE_SCRIPT}"; do
  install -m 0755 "${tool}" "${FIX}/without-helper/"
  rm -f "${FIX}/requests"
  out="$(env FAKE_DIR="${FIX}" PATH="${FIX}/bin:${PATH}" GHCR_TOKEN=fixture GHCR_DELETE_TAGS_CONFIRM=1 GHCR_PRUNE_CONFIRM=1 \
    bash "${FIX}/without-helper/${tool##*/}" drop 2>&1)"; rc=$?
  t_assert_eq 1 "${rc}"
  t_assert_contains "${out}" 'missing companion ghcr_metadata.py'
  t_assert_fails test -e "${FIX}/requests"
  t_assert_fails test -e "${FIX}/forbidden-request"
done

t_summary
t_summary
