#!/usr/bin/env bash
# A local Git client proves the type gate uses its pinned API; HTTP and filesystem behavior stay in runtime tests.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
S="$(cd "${TESTS_DIR}/.." && pwd)"
REPO="$(cd "${S}/../.." && pwd)"
t_skip_unless 'git' git --version
t_skip_unless 'uvx' uvx --version
t_case 'the Linux x64 preflight runs the pinned client type gate before its report upload'
workflow="$(cat "${REPO}/.github/workflows/linux-x64.yml")"
t_assert_contains "${workflow}" 'run: bash linux/scripts/01-core/check-webdav-types.sh'
t_assert_contains "${workflow#*run: bash linux/scripts/01-core/check-webdav-types.sh}" 'logs/code-quality/ty-*.txt'

mkdir -p "${REPO}/logs/test-results"
ROOT="$(mktemp -d "${REPO}/logs/test-results/webdav-types.XXXXXXXX")"
cleanup() {
  case "${ROOT}" in "${REPO}"/logs/test-results/webdav-types.*) rm -rf -- "${ROOT}" ;; esac
}
trap cleanup EXIT

core="${ROOT}/hub/linux/scripts/01-core"
client="${ROOT}/client"
mkdir -p "${core}" "${client}/kataglyphis_webdavclient"
cp "${S}/01-core/check-webdav-types.sh" "${core}/"
cp "${S}/01-core/load-versions-env.sh" "${core}/"
cp "${S}/01-core/load-ty-tool.sh" "${core}/"
cp "${S}/01-core/download-webdav-files.py" "${core}/"
sed -n '/^TY_VERSION=/p' "${S}/01-core/tool-pins.env" > "${core}/tool-pins.env"
: > "${client}/kataglyphis_webdavclient/__init__.py"
cat > "${client}/kataglyphis_webdavclient/webdavclient.py" <<'PY'
class WebDavClient:
    def __init__(self, hostname: str, username: str, password: str) -> None:
        pass

    def download_all_files_iterative(
        self, remote: str, local: str, *, extension: str | None = None
    ) -> int:
        return 2
PY
git -C "${client}" init -q
git -C "${client}" add kataglyphis_webdavclient
git -C "${client}" -c user.name=Fixture -c user.email=fixture@example.test commit -qm typed-client
ref="$(git -C "${client}" rev-parse HEAD)"
printf 'WEBDAVCLIENT_REF=%s\n' "${ref}" > "${core}/versions.env"

t_case 'bad arguments fail with a fresh ignored report before any tool setup'
out="$(bash "${core}/check-webdav-types.sh" --unknown 2>&1)" && rc=0 || rc=$?
t_assert_eq 2 "${rc}"
t_assert_ok test -f "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt"
t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" 'WebDAV type gate accepts only --source-url URL'

_check() {
  local output rc=0
  output="$(TY_VERSION=0.0.0 WEBDAVCLIENT_REF=0000000000000000000000000000000000000000 \
    bash "${core}/check-webdav-types.sh" --source-url "${client}" 2>&1)" || rc=$?
  printf '%s\nrc=%s\n' "${output}" "${rc}"
}

_check_without() {
  local target="$1" output
  mv -- "${target}" "${target}.hidden" || return
  output="$(_check)"
  mv -- "${target}.hidden" "${target}" || return
  printf '%s\n' "${output}"
}

_assert_result() {
  local output="$1" evidence="$2" status="$3"
  t_assert_contains "${output}" "${evidence}"
  t_assert_contains "${output}" "rc=${status}"
  t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" "${evidence}"
  if [ "${4:-}" = pinned ]; then
    t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" "${ref}"
  fi
}

t_case 'a missing version file keeps the original setup error in the ignored report'
out="$(_check_without "${core}/versions.env")"
_assert_result "${out}" 'WebDAV type gate needs a full lowercase commit pin' 2
t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" 'load_versions_env:'

t_case 'a missing pinned ty file leaves its setup error in the ignored report'
out="$(_check_without "${core}/tool-pins.env")"
_assert_result "${out}" 'ty tool pins are missing' 2

t_case 'a missing downloader leaves its setup error in the ignored report'
out="$(_check_without "${core}/download-webdav-files.py")"
_assert_result "${out}" 'WebDAV downloader is missing' 2

t_case 'the exact local commit resolves the typed client API without installing its runtime dependencies'
out="$(_check)"
_assert_result "${out}" 'All checks passed!' 0 pinned
t_assert_ok test -f "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt"

t_case 'the pinned client signature rejects an incorrect downloader call'
sed -i 's/extension=extension/extension=42/' "${core}/download-webdav-files.py"
out="$(_check)"
t_assert_contains "${out}" 'invalid-argument-type'
t_assert_contains "${out}" 'WebDAV type gate failed (exit 1)'
t_assert_contains "${out}" 'rc=1'
t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" 'invalid-argument-type'
cp "${S}/01-core/download-webdav-files.py" "${core}/"

t_case 'a missing pinned client file fails before a green checker verdict'
git -C "${client}" rm -q kataglyphis_webdavclient/webdavclient.py
git -C "${client}" -c user.name=Fixture -c user.email=fixture@example.test commit -qm missing-client
ref="$(git -C "${client}" rev-parse HEAD)"
printf 'WEBDAVCLIENT_REF=%s\n' "${ref}" > "${core}/versions.env"
out="$(_check)"
_assert_result "${out}" 'Pinned WebDAV source has no webdavclient.py' 2 pinned

t_case 'a valid-looking commit unavailable from the source fails the fetch'
printf 'WEBDAVCLIENT_REF=%040d\n' 0 > "${core}/versions.env"
out="$(_check)"
t_assert_contains "${out}" 'not our ref'
t_assert_fails test "${out##*rc=}" -eq 0
t_assert_contains "$(cat "${ROOT}/hub/logs/code-quality/ty-webdav-gate.txt")" 'WebDAV source fetch failed'

t_summary
