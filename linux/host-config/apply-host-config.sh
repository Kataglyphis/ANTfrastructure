#!/usr/bin/env bash
# Installs the canonical host config ([--force] skips the prompt); the buildkitd restart that kills builds is left to the operator.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_TOML="${HOME}/.config/buildkit/buildkitd.toml"
LIVE_DROPIN="${HOME}/.config/systemd/user/buildkit.service.d/override.conf"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=prefix-common.sh
source "${HERE}/prefix-common.sh"


if pgrep -f "build-cross-chain.sh|buildctl.*build" >/dev/null 2>&1; then
  err "a build chain / buildctl is RUNNING — applying restarts buildkitd and kills it. Retry when idle."
fi

_render_dir="$(mktemp -d)"
trap 'rm -rf "${_render_dir}"' EXIT

_changed=0
for pair in "buildkitd.toml:${LIVE_TOML}" "buildkit.service-override.conf:${LIVE_DROPIN}"; do
  src="${HERE}/${pair%%:*}"; dst="${pair#*:}"
  render_host_config "${src}" "${_render_dir}/${pair%%:*}"
  src="${_render_dir}/${pair%%:*}"
  if [ -f "${dst}" ] && diff -u "${dst}" "${src}"; then
    echo "in sync: ${dst}"
    continue
  fi
  _changed=1
  if [ "${1:-}" != "--force" ]; then
    printf 'Install %s -> %s ? [y/N] ' "${src##*/}" "${dst}"
    read -r _ans; [ "${_ans}" = "y" ] || { echo "skipped ${dst}"; continue; }
  fi
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
  echo "installed: ${dst}"
done

if [ "${_changed}" = "1" ]; then
  cat <<'EOF'

Config installed. To activate (operator step, NOT run by this script):
  systemctl --user daemon-reload
  systemctl --user restart buildkit.service
  # then verify:  bash linux/host-config/verify-host-config.sh
EOF
fi
