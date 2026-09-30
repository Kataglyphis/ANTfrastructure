#!/usr/bin/env bash
# ghcr-prune-package.sh: the keep-set gate counts digests, not tag names, and an unreadable tag digest aborts.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"

PRUNE="${TESTS_DIR}/../../host-config/ghcr-prune-package.sh"
FIX="$(mktemp -d)"
trap 'rm -rf "${FIX}"' EXIT
mkdir -p "${FIX}/bin" "${FIX}/manifests" "${FIX}/digests"

# Registry and API from files: versions.json, manifests/<tag>.json, digests/<tag> (absent = no digest header).
cat > "${FIX}/bin/curl" <<'EOF'
#!/usr/bin/env bash
head=0; url=""
for a in "$@"; do case "${a}" in -*I*) head=1 ;; http*) url="${a}" ;; esac; done
case "${url}" in
  *ghcr.io/token*) echo '{"token":"reg"}' ;;
  *'/versions?per_page=100&page=1') cat "${FAKE_DIR}/versions.json" ;;
  *'/versions?'*) echo '[]' ;;
  */manifests/*)
    tag="${url##*/}"
    [ -f "${FAKE_DIR}/manifests/${tag}.json" ] || exit 22
    if [ "${head}" = 1 ]; then
      [ -f "${FAKE_DIR}/digests/${tag}" ] && printf 'HTTP/2 200\r\ndocker-content-digest: %s\r\n\r\n' "$(cat "${FAKE_DIR}/digests/${tag}")"
      exit 0
    fi
    cat "${FAKE_DIR}/manifests/${tag}.json" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${FIX}/bin/curl"

# Two tags on one image (a rename in flight), one more tag, and two old untagged versions.
cat > "${FIX}/versions.json" <<'EOF'
[{"id": 1, "name": "sha256:d1", "created_at": "2026-09-01T00:00:00Z", "metadata": {"container": {"tags": ["latest", "latest-alias"]}}},
 {"id": 2, "name": "sha256:d2", "created_at": "2026-09-01T00:00:00Z", "metadata": {"container": {"tags": ["other"]}}},
 {"id": 3, "name": "sha256:d8", "created_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
 {"id": 4, "name": "sha256:d9", "created_at": "2020-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}}]
EOF
for tag in latest latest-alias other; do echo '{"schemaVersion": 2}' > "${FIX}/manifests/${tag}.json"; done
echo sha256:d1 > "${FIX}/digests/latest"
echo sha256:d1 > "${FIX}/digests/latest-alias"
echo sha256:d2 > "${FIX}/digests/other"

_prune() { env FAKE_DIR="${FIX}" PATH="${FIX}/bin:${PATH}" GHCR_TOKEN=pat MIN_TAGS=2 GHCR_PRUNE_CONFIRM=0 bash "${PRUNE}" 2>&1; }

t_case "two tags on one digest pass the keep-set gate (the 2026-09-27 false refusal)"
_out="$(_prune)"; _rc=$?
t_assert_eq "${_rc}" "0" "a dry run with an aliased tag exits 0"
t_assert_contains "${_out}" "3 tag(s) on 2 digest(s)" "the gate reports tags and distinct digests"
t_assert_contains "${_out}" "plan: delete 2 of 4 versions" "only the two old untagged versions are candidates"

t_case "a tag whose digest cannot be read aborts before any candidate is chosen"
rm -f "${FIX}/digests/other"
_out="$(_prune)"; _rc=$?
t_assert_eq "${_rc}" "1" "an unreadable tag digest refuses"
t_assert_contains "${_out}" "cannot read the digest of tag 'other'" "the refusal names the tag"
echo sha256:d2 > "${FIX}/digests/other"

t_summary
