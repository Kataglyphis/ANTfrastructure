#!/usr/bin/env bash
# resolve_qnn_sdk's pinned Community zip: fetched through the verified downloader when nothing is staged. docs/qnn-linux.md#staging
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
QNN_SH="${TESTS_DIR}/../01-core/qnn-sdk.sh"
t_private_tmpdir
# unzip is stubbed on PATH for the end-to-end case: it lays out the anchor header, the CPU backend and the STFT canary.
mkdir -p "${TMPDIR}/bin"
cat > "${TMPDIR}/bin/unzip" <<'UNZIP'
#!/usr/bin/env bash
# unzip -q -o <zip> -d <dir>: the extract dir is the fifth argument.
root="$5/qairt/2.51.1.261002"
mkdir -p "${root}/include/QNN" "${root}/lib/aarch64-oe-linux-gcc11.2"
: > "${root}/include/QNN/QnnInterface.h"
printf 'QNN_OP_STFT\n' > "${root}/include/QNN/QnnOpDef.h"
: > "${root}/lib/aarch64-oe-linux-gcc11.2/libQnnCpu.so"
UNZIP
chmod +x "${TMPDIR}/bin/unzip"

# The resolver's collaborators, stubbed: the downloader records its call and writes known bytes.
_qnn_stubs() {
  cat <<'STUBS'
info() { printf 'INFO %s\n' "$*" >&2; }
warn() { printf 'WARN %s\n' "$*" >&2; }
err() { printf 'ERR %s\n' "$*" >&2; exit 1; }
arch_oci() { printf 'arm64\n'; }
FETCH_LOG="${FETCH_LOG:?}"
download_verified_file() { printf '%s %s %s\n' "$1" "$2" "$3" >> "${FETCH_LOG}"; printf 'zipbytes\n' > "$3"; }
download_verify_sha256() { [ -f "$2" ] && [ "$1" = "$(cat "${QNN_SDK_CACHE_DIR}/.verified" 2>/dev/null)" ]; }
STUBS
  t_fn_src "${QNN_SH}" qnn_community_zip_url
  t_fn_src "${QNN_SH}" qnn_pinned_community_zip
  t_fn_src "${QNN_SH}" resolve_qnn_sdk
}

# _run "<env assignments>" <command...>: one subshell per case; stdout, then rc on the last line.
_run() {
  local assignments="$1"
  shift
  # shellcheck disable=SC2086 # the assignments are deliberately word-split
  env -i PATH="${PATH}" TMPDIR="${TMPDIR}" FETCH_LOG="${FETCH_LOG}" ${assignments} bash -c '
    set -u
    QNN_SDK_SOURCE="${QNN_SDK_SOURCE:-community}"
    QNN_SDK_CACHE_DIR="${QNN_SDK_CACHE_DIR:?}"
    QNN_SDK_LINUX_LIBDIR=aarch64-oe-linux-gcc11.2
    '"$(_qnn_stubs)"'
    ( "$@" ); printf "rc=%s\n" "$?"' _ "$@" 2>/dev/null
}

CACHE="$(t_mktemp -d)"
DROP="$(t_mktemp -d)"
FETCH_LOG="$(t_mktemp)"
_url="https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.51.1.261002/v2.51.1.261002.zip"

t_case "the Community zip URL is the software center's All/<v>/v<v>.zip shape"
t_assert_eq "${_url}" "$(_run "QNN_SDK_CACHE_DIR=${CACHE}" qnn_community_zip_url 2.51.1.261002 | head -n 1)" "exactly LiteRT's URL for that version"

t_case "no pin, or QNN_SDK_SOURCE=drop, fetches nothing and names no zip"
t_assert_eq "rc=0" "$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_VERSION=" qnn_pinned_community_zip)" "an empty version is silence, not an error"
t_assert_eq "rc=0" "$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_SOURCE=drop QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=ab" qnn_pinned_community_zip)" \
  "drop keeps the pre-2026-11-05 contract: only a staged zip counts"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "nothing was downloaded"

t_case "a version without its sha is refused: a pin moves with its checksum"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=" qnn_pinned_community_zip)"
t_assert_eq "rc=1" "${_out}" "rc 1 before any download"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "nothing was downloaded"

t_case "a cache miss downloads the pinned zip, lowercased sha, into the cache dir and names it"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=ABCDEF" qnn_pinned_community_zip)"
t_assert_eq "${CACHE}/qairt-2.51.1.261002.zip
rc=0" "${_out}" "the zip's path on stdout"
t_assert_eq "${_url} abcdef ${CACHE}/qairt-2.51.1.261002.zip" "$(cat "${FETCH_LOG}")" "one verified download, the sha as sha256sum wants it"
t_assert_eq "zipbytes" "$(cat "${CACHE}/qairt-2.51.1.261002.zip")" "the downloader wrote the cache file"

t_case "a cache hit that verifies is not downloaded again; one that does not verify is"
: > "${FETCH_LOG}"
printf 'abcdef' > "${CACHE}/.verified"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=abcdef" qnn_pinned_community_zip)"
t_assert_contains "${_out}" "rc=0" "a verified cached zip is used"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "no download for a verified cache hit"
printf 'other' > "${CACHE}/.verified"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=abcdef" qnn_pinned_community_zip)"
t_assert_eq "1" "$(grep -c . "${FETCH_LOG}")" "a cached zip that fails its sha is fetched again"

t_case "resolve_qnn_sdk: an empty drop dir under drop is QNN off; under community it fetches and resolves the SDK root"
: > "${FETCH_LOG}"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_SOURCE=drop QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=abcdef" resolve_qnn_sdk "${DROP}")"
t_assert_eq "rc=0" "${_out}" "QNN off: empty stdout, rc 0"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "and nothing downloaded"
# The stub downloader writes "zipbytes"; the resolver then hashes that file against the pin, so the pin is its sha256.
_zipsha="$(printf 'zipbytes\n' | sha256sum | awk '{print $1}')"
_out="$(_run "QNN_SDK_CACHE_DIR=${CACHE} QNN_SDK_EXTRACT_DIR=${TMPDIR}/extract QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_LINUX_ZIP_SHA256=${_zipsha} PATH=${TMPDIR}/bin:${PATH}" resolve_qnn_sdk "${DROP}")"
t_assert_contains "${_out}" "${TMPDIR}/extract/qairt/2.51.1.261002" "the SDK root under the extract dir, as the staged-zip path resolves it"
t_assert_contains "${_out}" "rc=0" "and rc 0"
t_assert_eq "1" "$(grep -c . "${FETCH_LOG}")" "one download fed the staged-zip path"

t_summary
