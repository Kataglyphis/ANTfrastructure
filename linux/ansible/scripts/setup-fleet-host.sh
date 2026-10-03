#!/usr/bin/env bash
# One-time per new Linux fleet host: installs the deploy key. Usage: setup-fleet-host.sh <host>
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <inventory-host-name>" >&2; exit 64; }
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/hostvars-lib.sh"
read_hostvars "$DIR/../inventory/host_vars/$1.yml"
exec ssh-copy-id -i "$DIR/../.ssh/id_ed25519.pub" "${USER}@${ADDR}"
