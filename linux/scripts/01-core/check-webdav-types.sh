#!/usr/bin/env bash
# Check the downloader against the pinned client API; HTTP and filesystem behavior need runtime tests.
set -euo pipefail

core_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${core_dir}/../../.." && pwd)"
report_dir="${root}/logs/code-quality"
mkdir -p "${report_dir}"
report="${report_dir}/ty-webdav-gate.txt"
printf 'WebDAV type gate setup\n' > "${report}"
report_failure() {
  printf '%s\n' "$2" >> "${report}"
  cat "${report}" >&2
  exit "$1"
}
source_url='https://github.com/Kataglyphis/WebDavClient.git'
case "${1:-}" in
  '') [ "$#" -eq 0 ] || report_failure 2 'WebDAV type gate accepts only --source-url URL' ;;
  --source-url)
    [ "$#" -eq 2 ] && [ -n "${2}" ] || report_failure 2 'WebDAV type gate needs one source URL'
    source_url="$2"
    ;;
  *) report_failure 2 'WebDAV type gate accepts only --source-url URL' ;;
esac

# shellcheck source=load-versions-env.sh
source "${core_dir}/load-versions-env.sh" >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV type gate could not load version helper'
# shellcheck source=load-ty-tool.sh
source "${core_dir}/load-ty-tool.sh" >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV type gate could not load ty helper'
unset WEBDAVCLIENT_REF
load_versions_env "${core_dir}/versions.env" >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV type gate could not load client pin'
ref="${WEBDAVCLIENT_REF:-}"
[[ "${ref}" =~ ^[0-9a-f]{40}$ ]] || report_failure 2 'WebDAV type gate needs a full lowercase commit pin'
printf 'Checking WebDAV source commit %s\n' "${ref}" >> "${report}"
load_ty_tool "${core_dir}/tool-pins.env" >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV type gate could not load pinned ty'

script="${core_dir}/download-webdav-files.py"
[ -f "${script}" ] || report_failure 2 "WebDAV downloader is missing at ${script}"
command -v git >/dev/null 2>&1 || report_failure 2 'git is required for the WebDAV type gate'

temp_root="${TMPDIR:-/tmp}"
checkout="$(mktemp -d "${temp_root}/webdav-types.XXXXXXXX" 2>> "${report}")" || \
  report_failure "$?" 'WebDAV type gate could not create temporary source directory'
cleanup() {
  case "${checkout}" in "${temp_root}"/webdav-types.*) rm -rf -- "${checkout}" ;; esac
}
trap cleanup EXIT

git -C "${checkout}" init -q >> "${report}" 2>&1 || report_failure "$?" 'WebDAV source init failed'
git -C "${checkout}" remote add origin "${source_url}" >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV source remote setup failed'
git -C "${checkout}" sparse-checkout init --cone >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV source sparse checkout setup failed'
git -C "${checkout}" sparse-checkout set kataglyphis_webdavclient >> "${report}" 2>&1 || \
  report_failure "$?" 'WebDAV source sparse checkout selection failed'
rc=0
git -C "${checkout}" fetch --quiet --no-tags --depth=1 --filter=blob:none origin "${ref}" >> "${report}" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] || report_failure "${rc}" "WebDAV source fetch failed (exit ${rc})"
actual="$(git -C "${checkout}" rev-parse FETCH_HEAD 2>> "${report}")" || \
  report_failure "$?" 'WebDAV source revision lookup failed'
[ "${actual}" = "${ref}" ] || report_failure 1 "WebDAV source commit mismatch: expected ${ref}, got ${actual}"
rc=0
git -C "${checkout}" checkout --quiet --detach "${ref}" >> "${report}" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] || report_failure "${rc}" "WebDAV source checkout failed (exit ${rc})"
[ -f "${checkout}/kataglyphis_webdavclient/webdavclient.py" ] || \
  report_failure 2 'Pinned WebDAV source has no webdavclient.py'

rc=0
uvx "ty@${TY_VERSION}" check --python-version 3.14 --python-platform linux \
  --extra-search-path "${checkout}" --output-format concise "${script}" >> "${report}" 2>&1 || rc=$?
cat "${report}"
[ "${rc}" -eq 0 ] || { echo "WebDAV type gate failed (exit ${rc})" >&2; exit "${rc}"; }
