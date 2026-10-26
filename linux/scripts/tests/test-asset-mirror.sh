#!/usr/bin/env bash
# The asset mirror in download_verified_file, its build secret, the Dockerfile mounts and fill-asset-mirror.sh, against a stubbed curl; see linux/sccache-s3/README.md#the-asset-mirror
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="$(cd "${TESTS_DIR}/.." && pwd)"
REPO="$(cd "${SCRIPTS}/../.." && pwd)"
DOWNLOADS="${SCRIPTS}/01-core/downloads.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export FAKE_CURL_ROOT="${WORK}/srv"
MIRROR="${FAKE_CURL_ROOT}/mirror.invalid"
UP="${FAKE_CURL_ROOT}/up.invalid"
mkdir -p "${UP}" "${MIRROR}"
t_fake_curl "${WORK}/bin"

printf 'the real asset\n' > "${UP}/tool.tar.gz"
SHA="$(sha256sum "${UP}/tool.tar.gz" | awk '{print $1}')"
URL="https://up.invalid/tool.tar.gz?raw=1"
mirror_put() {
  mkdir -p "${MIRROR}/assets/${SHA}"
  printf '%s' "$1" > "${MIRROR}/assets/${SHA}/tool.tar.gz"
}
mirror_reset() { rm -rf "${MIRROR}" "${FAKE_CURL_ROOT}/calls" "${FAKE_CURL_ROOT}/requested"; mkdir -p "${MIRROR}"; }

CFG="${WORK}/asset-mirror.env"
printf 'ASSET_MIRROR_URL=http://mirror.invalid/assets\nAWS_ACCESS_KEY_ID=GKkey\nAWS_SECRET_ACCESS_KEY=s3cr3tvalue\nAWS_REGION=garage\n' > "${CFG}"
chmod 600 "${CFG}"

# _fetch <dest> [env...]: rc|stderr of one download_verified_file, the host's own config files out of reach.
_fetch() {
  local dest="$1"; shift
  env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="${WORK}/home" FAKE_CURL_ROOT="${FAKE_CURL_ROOT}" DOWNLOAD_RETRY_DELAY=0 "$@" \
    bash -c 'source "$1"; download_verified_file "$2" "$3" "$4" 2>"$4.err"; rc=$?; printf "%s|%s" "${rc}" "$(cat "$4.err")"' \
    _ "${DOWNLOADS}" "${URL}" "${SHA}" "${dest}"
}
_calls() { grep -c -e "^$1" "${FAKE_CURL_ROOT}/calls" 2>/dev/null || true; }

t_case "no mirror configured: one upstream fetch, the mirror is never asked"
mirror_reset
out="$(_fetch "${WORK}/a1")"
t_assert_eq "0" "${out%%|*}"
t_assert_eq "0" "$(_calls http://mirror.invalid)" "no config means no mirror request"
t_assert_eq "1" "$(_calls https://up.invalid)"

t_case "a mirror hit with the pinned bytes: no upstream fetch"
mirror_reset; mirror_put "the real asset
"
out="$(_fetch "${WORK}/a2" KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}")"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out#*|}" "asset-mirror| hit tool.tar.gz"
t_assert_eq "0" "$(_calls https://up.invalid)" "a verified mirror copy must not also fetch upstream"
t_assert_eq "1" "$(_calls "http://mirror.invalid/assets/${SHA}/tool.tar.gz|")" "the object is <sha256>/<name>, the query stripped"

t_case "the key reaches curl on stdin, signed for the configured region, never in argv"
call="$(grep -e '^http://mirror.invalid' "${FAKE_CURL_ROOT}/calls")"
t_assert_contains "${call}" "--aws-sigv4 aws:amz:garage:s3"
t_assert_contains "${call##*|}" 'user = "GKkey:s3cr3tvalue"'
argv="${call#*|}"; argv="${argv%|*}"
case "${argv}" in *s3cr3tvalue*) t_assert_eq "absent" "present" "the secret was on curl's command line" ;; *) t_assert_eq "absent" "absent" ;; esac

t_case "a mirror miss falls back upstream and logs the line the fill script reads"
mirror_reset
out="$(_fetch "${WORK}/a3" KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}")"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out#*|}" "asset-mirror| miss ${SHA} ${URL} file"
t_assert_eq "the real asset" "$(cat "${WORK}/a3")"

t_case "a mirrored copy with the wrong bytes is refused and replaced by upstream's"
mirror_reset; mirror_put "tampered"
out="$(_fetch "${WORK}/a4" KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}")"
t_assert_eq "0" "${out%%|*}"
t_assert_contains "${out#*|}" "failed its checksum -- fetching upstream"
t_assert_eq "the real asset" "$(cat "${WORK}/a4")" "the shipped bytes are the pinned ones"
t_assert_eq "1" "$(_calls https://up.invalid)"

t_case "a mirror miss and a bad upstream fail, and leave nothing behind"
mirror_reset; cp "${UP}/tool.tar.gz" "${WORK}/good"; printf 'bad' > "${UP}/tool.tar.gz"
out="$(_fetch "${WORK}/a5" KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}")"
t_assert_eq "1" "${out%%|*}"
t_assert_eq "absent" "$([ -e "${WORK}/a5" ] && echo present || echo absent)"
cp "${WORK}/good" "${UP}/tool.tar.gz"

t_case "a mirror that takes no connection is skipped for the rest of the shell"
mirror_reset
env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="${WORK}/home" FAKE_CURL_ROOT="${FAKE_CURL_ROOT}" FAKE_CURL_FAIL_PREFIX=http://mirror.invalid DOWNLOAD_RETRY_DELAY=0 \
  KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}" bash -c 'source "$1"
  download_verified_file "$2" "$3" "$4/b1" && download_verified_file "$2" "$3" "$4/b2"' _ "${DOWNLOADS}" "${URL}" "${SHA}" "${WORK}" 2>"${WORK}/b.err"
t_assert_eq "1" "$(_calls http://mirror.invalid)" "the second download must not wait on a dead mirror again"
t_assert_eq "2" "$(_calls https://up.invalid)"
t_assert_grep "${WORK}/b.err" 'asset-mirror\| http://mirror.invalid/assets unreachable \(curl 7\)'

t_case "KATAGLYPHIS_ASSET_MIRROR=off ignores a configured mirror"
mirror_reset; mirror_put "the real asset
"
out="$(_fetch "${WORK}/a6" KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}" KATAGLYPHIS_ASSET_MIRROR=off)"
t_assert_eq "0" "${out%%|*}"
t_assert_eq "0" "$(_calls http://mirror.invalid)"

t_case "the RUN's secret file is found without any knob"
t_assert_contains "$(sed -n '/^download_mirror_config_file()/,/^}/p' "${DOWNLOADS}")" "/run/secrets/asset_mirror"

t_case "the build secret: passed for a private file with a URL, withheld otherwise"
_secret() { env -i PATH=/usr/bin:/bin HOME="${WORK}/home" "$@" bash -c 'source "$1/01-core/build-helpers.sh"; a=(); append_asset_mirror_secret a; printf "%s" "${a[*]}"' _ "${SCRIPTS}" 2>/dev/null; }
t_assert_eq "--secret id=asset_mirror,src=${CFG}" "$(_secret KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}")"
t_assert_eq "" "$(_secret KATAGLYPHIS_ASSET_MIRROR_FILE="${CFG}" KATAGLYPHIS_ASSET_MIRROR=off)"
cp "${CFG}" "${WORK}/open.env"; chmod 644 "${WORK}/open.env"
t_assert_eq "" "$(_secret KATAGLYPHIS_ASSET_MIRROR_FILE="${WORK}/open.env")" "a file others can read never becomes a secret"
printf 'AWS_ACCESS_KEY_ID=x\n' > "${WORK}/nourl.env"; chmod 600 "${WORK}/nourl.env"
t_assert_eq "" "$(_secret KATAGLYPHIS_ASSET_MIRROR_FILE="${WORK}/nourl.env")"
t_assert_eq "" "$(_secret KATAGLYPHIS_ASSET_MIRROR_FILE="${WORK}/missing.env")"
t_assert_contains "$(sed -n '/^append_common_build_args()/,/^}/p' "${SCRIPTS}/01-core/build-helpers.sh")" "append_asset_mirror_secret" \
  "every stage and runtime build gets the secret through append_common_build_args"

t_case "every Linux RUN that reads a hub script mounts the asset_mirror secret"
missing="$(PYTHONPATH="${TESTS_DIR}" python3 - "${REPO}"/linux/Dockerfile.* <<'PY'
import re
import sys

from dockerfile_runs import dockerfile_runs

reads = re.compile(r"source=linux/scripts/|/opt/scripts/\S*\.sh\b")
for path in sys.argv[1:]:
    for line, text in dockerfile_runs(path):
        if reads.search(text) and "--mount=type=secret,id=asset_mirror,required=false" not in text:
            print(f"{path}:{line}")
PY
)"
t_assert_eq "" "${missing}" "RUNs without the mirror secret fetch pinned assets from GitHub alone"

FILL_ROOT="${WORK}/hub"
mkdir -p "${FILL_ROOT}/linux/host-config" "${FILL_ROOT}/linux/scripts/01-core" "${FILL_ROOT}/logs"
cp "${REPO}/linux/host-config/fill-asset-mirror.sh" "${FILL_ROOT}/linux/host-config/"
cp "${DOWNLOADS}" "${FILL_ROOT}/linux/scripts/01-core/"
printf 'TOOL_SHA256=%s\n' "${SHA}" > "${FILL_ROOT}/linux/scripts/01-core/versions.env"
: > "${FILL_ROOT}/linux/scripts/01-core/tool-pins.env"
UNPINNED="$(printf 'x' | sha256sum | awk '{print $1}')"
printf '#12 4.2 asset-mirror| miss %s %s file\r\n#12 4.3 asset-mirror| miss %s https://up.invalid/other.bin file\n' "${SHA}" "${URL}" "${UNPINNED}" > "${FILL_ROOT}/logs/stage.log"
# _fill <want-rc> <args...>: runs the fill script into FILL_OUT and asserts its exit status.
_fill() {
  local want="$1" rc=0
  shift
  FILL_OUT="$(env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="${WORK}/home" FAKE_CURL_ROOT="${FAKE_CURL_ROOT}" DOWNLOAD_RETRY_DELAY=0 \
    KATAGLYPHIS_ASSET_MIRROR_FILL_FILE="${CFG}" bash "${FILL_ROOT}/linux/host-config/fill-asset-mirror.sh" "$@" 2>&1)" || rc=$?
  t_assert_eq "${want}" "${rc}" "fill-asset-mirror.sh $*: ${FILL_OUT}"
}
_mirrored() { if [ -e "${MIRROR}/assets/${SHA}/tool.tar.gz" ]; then echo present; else echo absent; fi; }

t_case "fill dry run: plans the pinned miss, skips the unpinned one, uploads nothing"
mirror_reset
_fill 0 "${FILL_ROOT}/logs"
t_assert_contains "${FILL_OUT}" "would    ${SHA:0:12} tool.tar.gz <- ${URL}"
t_assert_contains "${FILL_OUT}" "skip     ${UNPINNED:0:12} other.bin: not a digest"
t_assert_eq "absent" "$(_mirrored)"

t_case "fill --apply uploads the verified bytes under <sha256>/<name> and reads them back"
_fill 0 --apply "${FILL_ROOT}/logs"
t_assert_contains "${FILL_OUT}" "mirrored ${SHA:0:12} tool.tar.gz"
t_assert_eq "the real asset" "$(cat "${MIRROR}/assets/${SHA}/tool.tar.gz" 2>/dev/null)"

t_case "fill is idempotent: a present object is left alone"
puts="$(grep -c -e ' -T ' "${FAKE_CURL_ROOT}/calls")"
_fill 0 --apply "${FILL_ROOT}/logs"
t_assert_contains "${FILL_OUT}" "present  ${SHA:0:12} tool.tar.gz"
t_assert_eq "${puts}" "$(grep -c -e ' -T ' "${FAKE_CURL_ROOT}/calls")" "no second upload of a present object"

t_case "fill refuses bytes that do not match the pin, and fails"
mirror_reset; printf 'bad' > "${UP}/tool.tar.gz"
_fill 1 --apply --url "${URL}" --sha "${SHA}"
t_assert_contains "${FILL_OUT}" "FAILED   ${SHA:0:12} tool.tar.gz"
t_assert_eq "absent" "$(_mirrored)"
cp "${WORK}/good" "${UP}/tool.tar.gz"

t_case "fill refuses a credentials file others can read"
t_assert_rc 2 env -i PATH="${WORK}/bin:/usr/bin:/bin" HOME="${WORK}/home" KATAGLYPHIS_ASSET_MIRROR_FILL_FILE="${WORK}/open.env" \
  bash "${FILL_ROOT}/linux/host-config/fill-asset-mirror.sh" --url "${URL}" --sha "${SHA}"

t_summary
