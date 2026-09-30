#!/usr/bin/env bash
# Live vs canonical host config; warn-only unless --strict, since CI runners and fresh hosts lack the live files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_TOML="${HOME}/.config/buildkit/buildkitd.toml"
LIVE_DROPIN="${HOME}/.config/systemd/user/buildkit.service.d/override.conf"
STRICT=0; [ "${1:-}" = "--strict" ] && STRICT=1
DRIFT=0

# shellcheck source=prefix-common.sh
source "${HERE}/prefix-common.sh"

_render_dir="$(mktemp -d)"
trap 'rm -rf "${_render_dir}"' EXIT

check() { # check <repo-file> <live-file>
  local src="${HERE}/$1" dst="$2"
  render_host_config "${src}" "${_render_dir}/$1"; src="${_render_dir}/$1"
  if [ ! -f "${dst}" ]; then
    echo "NOTE: ${dst} absent (fresh host / CI runner?) — apply-host-config.sh installs it."
    DRIFT=1
    return
  fi
  if diff -q "${dst}" "${src}" >/dev/null 2>&1; then
    echo "in sync: ${dst}"
  else
    echo "DRIFT: ${dst} differs from linux/host-config/$1 —"
    diff -u "${src}" "${dst}" | sed 's/^/  /' | head -30
    echo "  (live wins silently today; reconcile via apply-host-config.sh or update the repo copy)"
    DRIFT=1
  fi
}

check "buildkitd.toml" "${LIVE_TOML}"
check "buildkit.service-override.conf" "${LIVE_DROPIN}"

if [ "${DRIFT}" = "1" ] && [ "${STRICT}" = "1" ]; then
  exit 1
fi
exit 0
