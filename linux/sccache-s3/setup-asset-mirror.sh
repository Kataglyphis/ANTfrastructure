#!/usr/bin/env bash
# On the Garage host, as root: creates release-assets, its read and fill keys, and their env files (--url URL [--out DIR] [--bucket B]): linux/sccache-s3/README.md#the-asset-mirror
set -euo pipefail

URL="" OUT=/root BUCKET=release-assets
: "${GARAGE_CONFIG_FILE:=/etc/garage/garage.toml}"
export GARAGE_CONFIG_FILE

# Sourced before die(): the logging bootstrap brings its own die, which exits 1.
# shellcheck source=../host-config/host-cli.sh
source "$(dirname "${BASH_SOURCE[0]}")/../host-config/host-cli.sh"
die() { printf 'setup-asset-mirror: %s\n' "$*" >&2; exit 2; }

# shellcheck disable=SC2034  # read by name in parse_cli_value_options
declare -A VALUE_OPTIONS=([--url]=URL [--out]=OUT [--bucket]=BUCKET)
host_cli_parse "$0" VALUE_OPTIONS - "$@"
[ -n "${OUT}" ] && [ -n "${BUCKET}" ] || die "--out and --bucket need a value"
[ -n "${URL}" ] || die "--url is required, e.g. http://<s3-server-lan-ip>:3900/${BUCKET}"
URL="${URL%/}"
case "${URL}" in */"${BUCKET}") ;; *) die "--url ${URL} does not end in /${BUCKET}" ;; esac
command -v garage >/dev/null || die "garage is not on PATH"
[ -r "${GARAGE_CONFIG_FILE}" ] || die "cannot read ${GARAGE_CONFIG_FILE}; set GARAGE_CONFIG_FILE"

# Re-running is safe: an existing bucket or key is kept, so a second host reuses the same keys.
garage bucket info "${BUCKET}" >/dev/null 2>&1 || garage bucket create "${BUCKET}"
for k in read fill; do
  garage key info "asset-mirror-${k}" >/dev/null 2>&1 || garage key create "asset-mirror-${k}" >/dev/null
done
garage bucket allow --read "${BUCKET}" --key asset-mirror-read
garage bucket allow --read --write "${BUCKET}" --key asset-mirror-fill

for k in read fill; do
  info="$(garage key info --show-secret "asset-mirror-${k}")"
  id="$(awk '/Key ID:/ {print $NF}' <<<"${info}")"
  secret="$(awk '/Secret key:/ {print $NF}' <<<"${info}")"
  [ -n "${id}" ] && [ -n "${secret}" ] \
    || die "cannot parse asset-mirror-${k}; read 'garage key info --show-secret asset-mirror-${k}'"
  (umask 077; printf '%s\n' "ASSET_MIRROR_URL=${URL}" "AWS_ACCESS_KEY_ID=${id}" \
    "AWS_SECRET_ACCESS_KEY=${secret}" "AWS_REGION=garage" > "${OUT}/asset-mirror-${k}.env")
done
printf 'setup-asset-mirror: wrote %s/asset-mirror-read.env and asset-mirror-fill.env; fetch them with linux/host-config/set-asset-mirror.sh\n' "${OUT}"
