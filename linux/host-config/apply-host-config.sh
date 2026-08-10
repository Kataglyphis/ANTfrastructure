#!/usr/bin/env bash
# apply-host-config.sh — install the canonical host config (backlog HC1).
#
#   bash linux/host-config/apply-host-config.sh          # diff + prompt
#   bash linux/host-config/apply-host-config.sh --force  # no prompt
#
# REFUSES to run while a cross chain / buildkit build is active: applying
# means restarting buildkitd, which kills in-flight builds. Restart is the
# operator's explicit last step (printed, not executed) so a typo'd sudo
# session can't bounce the daemon by accident.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_TOML="${HOME}/.config/buildkit/buildkitd.toml"
LIVE_DROPIN="${HOME}/.config/systemd/user/buildkit.service.d/override.conf"

err() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

if pgrep -f "build-cross-chain.sh|buildctl.*build" >/dev/null 2>&1; then
  err "a build chain / buildctl is RUNNING — applying restarts buildkitd and kills it. Retry when idle."
fi

_changed=0
for pair in "buildkitd.toml:${LIVE_TOML}" "buildkit.service-override.conf:${LIVE_DROPIN}"; do
  src="${HERE}/${pair%%:*}"; dst="${pair#*:}"
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
