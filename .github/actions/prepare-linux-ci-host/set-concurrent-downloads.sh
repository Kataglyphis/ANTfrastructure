#!/usr/bin/env bash
# set-concurrent-downloads.sh N: docker's parallel layer downloads (default 3) into daemon.json, then a daemon restart.
set -euo pipefail

count="${1:?a download count is required}"
case "${count}" in
  '' | *[!0-9]* | 0) echo "::error::max-concurrent-downloads must be a positive number, not '${count}'" >&2; exit 1 ;;
esac

conf=/etc/docker/daemon.json
current="$(sudo cat "${conf}" 2>/dev/null || true)"
[ -n "${current}" ] || current='{}'
# Merged, not overwritten: the runner image keeps its own keys there.
printf '%s' "${current}" | jq --argjson n "${count}" '. + {"max-concurrent-downloads": $n}' | sudo tee "${conf}" >/dev/null
sudo systemctl restart docker
for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    echo "docker restarted with max-concurrent-downloads=${count}: $(sudo jq -c . "${conf}")"
    exit 0
  fi
  sleep 1
done
echo "::error::docker did not answer within 30 s of its restart" >&2
exit 1
