#!/usr/bin/env bash
# Mirrors the pinned assets a chain fetched upstream ([--apply] [--url URL --sha SHA [--stream]] [log paths…], dry run by default): linux/sccache-s3/README.md#the-asset-mirror
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${HERE}/../scripts/01-core"
REPO="$(cd "${HERE}/../.." && pwd)"
FILE="${KATAGLYPHIS_ASSET_MIRROR_FILL_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/kataglyphis/asset-mirror-fill.env}"
PIN_FILES=("${CORE}/versions.env" "${CORE}/tool-pins.env")
APPLY=0 PENDING_URL=""
declare -a LOGS=() WANT=()

die() { printf 'fill-asset-mirror: %s\n' "$*" >&2; exit 2; }

# shellcheck source=../scripts/01-core/downloads.sh
source "${CORE}/downloads.sh"
declare -F download_mirror_curl >/dev/null || die "${CORE}/downloads.sh has no download_mirror_curl"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --url)
      [ -z "${PENDING_URL}" ] || die "--url ${PENDING_URL} needs --sha"
      PENDING_URL="${2:?--url needs a URL}"; shift 2 ;;
    --sha)
      [ -n "${PENDING_URL}" ] || die "--sha follows --url"
      WANT+=("${2:?--sha needs a digest} ${PENDING_URL} file"); PENDING_URL=""; shift 2 ;;
    --stream)
      [ "${#WANT[@]}" -gt 0 ] || die "--stream follows --sha"
      WANT[-1]="${WANT[-1]% file} stream"; shift ;;
    -h|--help) sed -n '2p' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) LOGS+=("$1"); shift ;;
  esac
done
[ -z "${PENDING_URL}" ] || die "--url ${PENDING_URL} needs --sha"
[ "${#WANT[@]}" -gt 0 ] || [ "${#LOGS[@]}" -gt 0 ] || LOGS=("${REPO}/logs/build-logs")

[ -r "${FILE}" ] || die "no fill credentials: ${FILE} (ASSET_MIRROR_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION; mode 600)"
[ -z "$(find "${FILE}" -perm /077 2>/dev/null)" ] || die "${FILE} is readable by others; chmod 600 it"
BASE="$(download_mirror_value "${FILE}" ASSET_MIRROR_URL)"
[ -n "${BASE}" ] || die "${FILE} has no ASSET_MIRROR_URL"
BASE="${BASE%/}"

if [ "${#LOGS[@]}" -gt 0 ]; then
  # BuildKit prefixes each output line, so match the marker anywhere in it.
  while IFS= read -r line; do
    WANT+=("${line#asset-mirror| miss }")
  done < <(grep -rhoE -e 'asset-mirror\| miss [0-9a-f]{64} [^[:space:]]+ (file|stream)' "${LOGS[@]}" 2>/dev/null | tr -d '\r' || true)
fi

mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | grep -v '^$' | LC_ALL=C sort -u || true)
[ "${#WANT[@]}" -gt 0 ] || { printf 'fill-asset-mirror: nothing to mirror (no miss lines in %s)\n' "${LOGS[*]}"; exit 0; }

present=0 planned=0 mirrored=0 skipped=0 failed=0
work="$(mktemp -d)"
for w in "${WANT[@]}"; do
  read -r sha url mode <<<"${w}"
  name="$(download_mirror_object_name "${url}")"
  obj="${BASE}/${sha}/${name}"
  # Only a digest the repo pins is mirrored: the pin, not the log line, vouches for the bytes.
  if ! grep -qE -e "^[A-Z0-9_]+=${sha}\$" "${PIN_FILES[@]}"; then
    printf 'skip     %s %s: not a digest versions.env or tool-pins.env pins\n' "${sha:0:12}" "${name}"
    skipped=$((skipped + 1)); continue
  fi
  if download_mirror_curl "${FILE}" -I -o /dev/null "${obj}" 2>/dev/null; then
    printf 'present  %s %s\n' "${sha:0:12}" "${name}"
    present=$((present + 1)); continue
  fi
  if [ "${APPLY}" -ne 1 ]; then
    printf 'would    %s %s <- %s\n' "${sha:0:12}" "${name}" "${url}"
    planned=$((planned + 1)); continue
  fi
  got="${work}/up" back="${work}/back"
  rm -f "${got}" "${back}"
  if KATAGLYPHIS_ASSET_MIRROR=off download_verified_file "${url}" "${sha}" "${got}" "${mode}" \
    && download_mirror_curl "${FILE}" -T "${got}" -o /dev/null "${obj}" \
    && download_mirror_curl "${FILE}" -o "${back}" "${obj}" \
    && download_verify_sha256 "${sha}" "${back}" "${mode}"; then
    printf 'mirrored %s %s\n' "${sha:0:12}" "${name}"
    mirrored=$((mirrored + 1))
  else
    printf 'FAILED   %s %s <- %s\n' "${sha:0:12}" "${name}" "${url}" >&2
    failed=$((failed + 1))
  fi
done
rm -rf "${work}"

printf 'fill-asset-mirror: %d present, %d mirrored, %d planned, %d skipped, %d failed%s\n' \
  "${present}" "${mirrored}" "${planned}" "${skipped}" "${failed}" "$([ "${APPLY}" -eq 1 ] || printf ' (dry run; --apply uploads)')"
[ "${failed}" -eq 0 ]
