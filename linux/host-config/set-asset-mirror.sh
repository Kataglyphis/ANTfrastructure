#!/usr/bin/env bash
# Installs this host's asset-mirror keys from the Garage host and proves their rights (--from SSH_TARGET [--url BUCKET_URL] [--remote-dir DIR] | --check): linux/sccache-s3/README.md#the-asset-mirror
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${HERE}/../scripts/01-core"
DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/kataglyphis"
READ="${KATAGLYPHIS_ASSET_MIRROR_FILE:-${DIR}/asset-mirror.env}"
FILL="${KATAGLYPHIS_ASSET_MIRROR_FILL_FILE:-${DIR}/asset-mirror-fill.env}"
FROM="" URL="" REMOTE_DIR=/root MODE=""

# Sourced before die(): the logging bootstrap brings its own die, which exits 1.
# shellcheck source=host-cli.sh
source "${HERE}/host-cli.sh"
die() { printf 'set-asset-mirror: %s\n' "$*" >&2; exit 2; }

_switch() {
  case "$1" in
    --check) MODE=check; return 1 ;;
  esac
  return 0
}
# shellcheck disable=SC2034  # read by name in parse_cli_value_options
declare -A VALUE_OPTIONS=([--from]=FROM [--url]=URL [--remote-dir]=REMOTE_DIR)
host_cli_parse "$0" VALUE_OPTIONS _switch "$@"
if [ -z "${MODE}" ] && [ -n "${FROM}" ]; then MODE=install; fi
[ -n "${MODE}" ] || die "pass --from SSH_TARGET (e.g. root@<s3-server-lan-ip>) or --check"
[ -n "${REMOTE_DIR}" ] || die "--remote-dir needs a directory"

# shellcheck source=../scripts/01-core/downloads.sh
source "${CORE}/downloads.sh"
declare -F download_mirror_curl >/dev/null || die "${CORE}/downloads.sh has no download_mirror_curl"

# The Garage host has no checkout, so the setup script travels with the files it sources.
SETUP_CLOSURE=(sccache-s3/setup-asset-mirror.sh host-config/host-cli.sh scripts/lib/cli-value-options.sh scripts/lib/log-bootstrap.sh)

# shellcheck disable=SC2029  # the remote command is built here from this host's values, quoted with %q
remote_setup() {
  local d rc=0
  d="$(ssh "${FROM}" 'mktemp -d')"
  case "${d}" in /*/tmp.??????????) ;; *) die "unexpected temp directory from ${FROM}: ${d}" ;; esac
  tar -C "${HERE}/.." -cf - "${SETUP_CLOSURE[@]}" | ssh "${FROM}" "tar -C $(printf %q "${d}") -xf -"
  ssh "${FROM}" "bash $(printf %q "${d}/sccache-s3/setup-asset-mirror.sh") --url $(printf %q "${URL}") --out $(printf %q "${REMOTE_DIR}")" || rc=$?
  ssh "${FROM}" "rm -rf $(printf %q "${d}")"
  [ "${rc}" = 0 ] || die "setup-asset-mirror.sh failed on ${FROM} (rc ${rc})"
}

install_keys() {
  mkdir -p "$(dirname "${READ}")" "$(dirname "${FILL}")"
  (umask 077
    scp -q "${FROM}:${REMOTE_DIR}/asset-mirror-read.env" "${READ}"
    scp -q "${FROM}:${REMOTE_DIR}/asset-mirror-fill.env" "${FILL}")
  chmod 600 "${READ}" "${FILL}"
  # The Garage host keeps no second copy of the secrets once this host holds them.
  # shellcheck disable=SC2029  # REMOTE_DIR is this host's argument, expanded here on purpose
  ssh "${FROM}" "rm -f '${REMOTE_DIR}/asset-mirror-read.env' '${REMOTE_DIR}/asset-mirror-fill.env'"
  printf 'set-asset-mirror: installed %s and %s\n' "${READ}" "${FILL}"
}

# <label> <want 0|1> <config> <curl args...>: one rights probe; a probe that answers the wrong way fails the check.
_probe() {
  local label="$1" want="$2" file="$3" got=1
  shift 3
  download_mirror_curl "${file}" -o /dev/null "$@" 2>/dev/null && got=0
  if [ "${got}" = "${want}" ]; then
    printf '  OK   %s\n' "${label}"
    return 0
  fi
  printf '  FAIL %s\n' "${label}" >&2
  return 1
}

check_keys() {
  local f url obj bad=0
  for f in "${READ}" "${FILL}"; do
    [ -f "${f}" ] || die "${f} does not exist; run with --from first"
    [ "$(stat -c '%a' "${f}")" = 600 ] || die "${f} is not mode 600"
  done
  url="$(download_mirror_value "${READ}" ASSET_MIRROR_URL)"
  [ -n "${url}" ] || die "${READ} names no ASSET_MIRROR_URL"
  obj="${url%/}/_probe/$(hostname)-$$"
  printf 'set-asset-mirror: probing %s\n' "${url}"
  _probe "read key lists the bucket" 0 "${READ}" "${url%/}?list-type=2" || bad=1
  _probe "read key cannot write" 1 "${READ}" -X PUT --data-binary probe "${obj}" || bad=1
  _probe "fill key writes" 0 "${FILL}" -X PUT --data-binary probe "${obj}" || bad=1
  _probe "read key reads what fill wrote" 0 "${READ}" "${obj}" || bad=1
  _probe "fill key deletes its probe" 0 "${FILL}" -X DELETE "${obj}" || bad=1
  [ "${bad}" = 0 ] || { printf 'set-asset-mirror: the keys do not have the rights the chain expects\n' >&2; return 1; }
  printf 'set-asset-mirror: both keys work\n'
}

if [ "${MODE}" = install ] && [ -n "${URL}" ]; then remote_setup; fi
[ "${MODE}" = check ] || install_keys
check_keys
