#!/usr/bin/env bash
# Stores this host's key for sccache's shared S3 level (--endpoint URL --access-key-id ID [--bucket B] [--region R] | --report | --clear): docs/linux-host-setup.md#b9-the-shared-s3-level-for-sccache
set -euo pipefail

FILE="${KATAGLYPHIS_SCCACHE_S3_FILE:-${XDG_CONFIG_HOME:-${HOME}/.config}/kataglyphis/sccache-s3.env}"
ENDPOINT="" KEY_ID="" BUCKET=sccache REGION=garage MODE=set

die() { printf 'set-sccache-s3-level: %s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT="${2:?--endpoint needs a URL}"; shift 2 ;;
    --access-key-id) KEY_ID="${2:?--access-key-id needs an id}"; shift 2 ;;
    --bucket) BUCKET="${2:?--bucket needs a name}"; shift 2 ;;
    --region) REGION="${2:?--region needs a name}"; shift 2 ;;
    --report) MODE=report; shift ;;
    --clear) MODE=clear; shift ;;
    -h|--help) sed -n '2p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "${MODE}" in
  report)
    [ -f "${FILE}" ] || { printf 'not set (%s does not exist)\n' "${FILE}"; exit 0; }
    printf '%s (%s)\n' "${FILE}" "$(stat -c '%a %U' "${FILE}")"
    sed -E 's/^(AWS_SECRET_ACCESS_KEY=).+/\1(set)/' "${FILE}"
    exit 0 ;;
  clear)
    rm -f "${FILE}"
    printf 'removed %s; the next chain builds without the S3 level\n' "${FILE}"
    exit 0 ;;
esac

[ -n "${ENDPOINT}" ] && [ -n "${KEY_ID}" ] || die "--endpoint and --access-key-id are required (or --report / --clear)"
case "${ENDPOINT}" in http://*|https://*) ;; *) die "--endpoint must be an http:// or https:// URL, got ${ENDPOINT}" ;; esac
ENDPOINT="${ENDPOINT%/}"

# Piped input is taken as is, so the key can come from a file without touching the terminal.
if [ -t 0 ]; then
  read -r -s -p "Secret key for ${KEY_ID}: " SECRET; printf '\n'
else
  IFS= read -r SECRET || true
fi
# A pasted command line was stored as the secret once (Windows, 2026-10-15).
case "${SECRET}" in ''|*[[:space:]]*) die "the secret is empty or holds whitespace -- nothing stored" ;; esac

# A signed ListObjects proves the key first; it reaches curl on stdin, since ps shows a command line.
code="$(printf 'user = "%s:%s"\n' "${KEY_ID}" "${SECRET}" | curl -s -m 10 -K - -o /dev/null -w '%{http_code}' \
  --aws-sigv4 "aws:amz:${REGION}:s3" "${ENDPOINT}/${BUCKET}?list-type=2&max-keys=1" || true)"
case "${code}" in
  200) printf 'key accepted: bucket %s at %s lists with it\n' "${BUCKET}" "${ENDPOINT}" ;;
  403) die "the bucket refused the key (HTTP 403) -- nothing stored" ;;
  404) die "bucket ${BUCKET} does not exist at ${ENDPOINT} (HTTP 404) -- nothing stored" ;;
  000) printf 'WARNING: %s did not answer; the key is stored unchecked, and builds skip the level while it stays unreachable\n' "${ENDPOINT}" >&2 ;;
  *) die "unexpected HTTP ${code} from ${ENDPOINT}/${BUCKET} -- nothing stored" ;;
esac

case "${ENDPOINT}" in https://*) SSL=true ;; *) SSL=false ;; esac
mkdir -p "$(dirname "${FILE}")"
(
  umask 077
  printf '%s\n' \
    "SCCACHE_BUCKET=${BUCKET}" \
    "SCCACHE_ENDPOINT=${ENDPOINT}" \
    "SCCACHE_REGION=${REGION}" \
    "SCCACHE_S3_USE_SSL=${SSL}" \
    "AWS_ACCESS_KEY_ID=${KEY_ID}" \
    "AWS_SECRET_ACCESS_KEY=${SECRET}" > "${FILE}.tmp"
)
mv -f "${FILE}.tmp" "${FILE}"
chmod 600 "${FILE}"
printf 'stored %s (600); the next build-cross-chain.sh run prints "sccache levels: disk -> s3 %s"\n' "${FILE}" "${ENDPOINT}"
