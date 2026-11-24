#!/usr/bin/env bash
# Fake downloads and extraction prove SDK selection and environment argv, not real transfers, installation or inference.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
QNN_SH="${TESTS_DIR}/../01-core/qnn-sdk.sh"
# Fresh fixture defaults keep inherited SDK settings out of the clean child environment.
QNN_SDK_SOURCE=community
QNN_SDK_VERSION=
QNN_SDK_ZIP_SHA256=
QNN_SDK_EXTRACT_DIR=
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

# Fresh child shells isolate resolver state while environment values retain their argument boundaries.
_run() {
  env -i PATH="${PATH}" TMPDIR="${TMPDIR}" FETCH_LOG="${FETCH_LOG}" \
    QNN_SDK_SOURCE="${QNN_SDK_SOURCE:-community}" QNN_SDK_CACHE_DIR="${QNN_SDK_CACHE_DIR:?}" \
    QNN_SDK_VERSION="${QNN_SDK_VERSION:-}" QNN_SDK_ZIP_SHA256="${QNN_SDK_ZIP_SHA256:-}" \
    QNN_SDK_EXTRACT_DIR="${QNN_SDK_EXTRACT_DIR:-}" bash -c '
    set -u
    QNN_SDK_LINUX_LIBDIR=aarch64-oe-linux-gcc11.2
    '"$(_qnn_stubs)"'
    ( "$@" ); printf "rc=%s\n" "$?"' _ "$@" 2>/dev/null
}

CACHE="$(t_mktemp -d)"
DROP="$(t_mktemp -d)"
FETCH_LOG="$(t_mktemp)"
_url="https://softwarecenter.qualcomm.com/api/download/software/sdks/Qualcomm_AI_Runtime_Community/All/2.51.1.261002/v2.51.1.261002.zip"

t_case "the Community zip URL is the software center's All/<v>/v<v>.zip shape"
t_assert_eq "${_url}" "$(QNN_SDK_CACHE_DIR="${CACHE}" _run qnn_community_zip_url 2.51.1.261002 | head -n 1)" "exactly LiteRT's URL for that version"

t_case "no pin, or QNN_SDK_SOURCE=drop, fetches nothing and names no zip"
t_assert_eq "rc=0" "$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_VERSION='' _run qnn_pinned_community_zip)" "an empty version is silence, not an error"
t_assert_eq "rc=0" "$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_SOURCE=drop QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256=ab _run qnn_pinned_community_zip)" \
  "drop keeps the pre-2026-11-05 contract: only a staged zip counts"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "nothing was downloaded"

t_case "a version without its sha is refused: a pin moves with its checksum"
_out="$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256='' _run qnn_pinned_community_zip)"
t_assert_eq "rc=1" "${_out}" "rc 1 before any download"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "nothing was downloaded"

t_case "a cache miss downloads the pinned zip, lowercased sha, into the cache dir and names it"
_out="$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256=ABCDEF _run qnn_pinned_community_zip)"
t_assert_eq "${CACHE}/qairt-2.51.1.261002.zip
rc=0" "${_out}" "the zip's path on stdout"
t_assert_eq "${_url} abcdef ${CACHE}/qairt-2.51.1.261002.zip" "$(cat "${FETCH_LOG}")" "one verified download, the sha as sha256sum wants it"
t_assert_eq "zipbytes" "$(cat "${CACHE}/qairt-2.51.1.261002.zip")" "the downloader wrote the cache file"

t_case "a cache hit that verifies is not downloaded again; one that does not verify is"
: > "${FETCH_LOG}"
printf 'abcdef' > "${CACHE}/.verified"
_out="$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256=abcdef _run qnn_pinned_community_zip)"
t_assert_contains "${_out}" "rc=0" "a verified cached zip is used"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "no download for a verified cache hit"
printf 'other' > "${CACHE}/.verified"
_out="$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256=abcdef _run qnn_pinned_community_zip)"
t_assert_eq "1" "$(grep -c . "${FETCH_LOG}")" "a cached zip that fails its sha is fetched again"

t_case "resolve_qnn_sdk: an empty drop dir under drop is QNN off; under community it fetches and resolves the SDK root"
: > "${FETCH_LOG}"
_out="$(QNN_SDK_CACHE_DIR="${CACHE}" QNN_SDK_SOURCE=drop QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256=abcdef _run resolve_qnn_sdk "${DROP}")"
t_assert_eq "rc=0" "${_out}" "QNN off: empty stdout, rc 0"
t_assert_eq "" "$(cat "${FETCH_LOG}")" "and nothing downloaded"
# The fake archive's actual bytes supply the checksum for both path layouts.
_zipsha="$(printf 'zipbytes\n' | sha256sum | awk '{print $1}')"
for _layout in plain spaced; do
  t_case "resolve_qnn_sdk preserves the ${_layout} fixture environment"
  _cache="${CACHE}"
  _extract="${TMPDIR}/extract"
  _path="${TMPDIR}/bin:${PATH}"
  if [ "${_layout}" = spaced ]; then
    _cache="${TMPDIR}/cache directory [qnn]"
    _extract="${TMPDIR}/extract directory [qnn]"
    _path="${TMPDIR}/bin:${TMPDIR}/tool paths [qnn]:${PATH}"
  fi
  : > "${FETCH_LOG}"
  _out="$(QNN_SDK_CACHE_DIR="${_cache}" QNN_SDK_EXTRACT_DIR="${_extract}" QNN_SDK_VERSION=2.51.1.261002 QNN_SDK_ZIP_SHA256="${_zipsha}" PATH="${_path}" _run resolve_qnn_sdk "${DROP}")"
  t_assert_contains "${_out}" "${_extract}/qairt/2.51.1.261002" "the SDK root retains the complete extract directory"
  t_assert_contains "${_out}" "rc=0" "the resolver completed"
  t_assert_eq "1" "$(grep -c . "${FETCH_LOG}")" "one download fed the staged-zip path"
  t_assert_eq "zipbytes" "$(cat "${_cache}/qairt-2.51.1.261002.zip")" "the complete cache directory received the bytes"
  t_assert_eq "${_url} ${_zipsha} ${_cache}/qairt-2.51.1.261002.zip" "$(cat "${FETCH_LOG}")" "the downloader received complete arguments"
done

t_summary
