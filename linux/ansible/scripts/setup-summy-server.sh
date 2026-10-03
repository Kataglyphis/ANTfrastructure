#!/usr/bin/env bash
# One-time Windows fleet bootstrap — values come from the gitignored host_vars.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
KEY=linux/ansible/.ssh/id_ed25519.pub
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/hostvars-lib.sh"
read_hostvars "$DIR/../inventory/host_vars/summy-server.yml"
USERHOST="${USER}@${ADDR}"

PUB=$(cat "$KEY")
echo "Installing the deploy key into the ADMINISTRATORS file (password prompt follows)…"
ssh "$USERHOST" "powershell -NoProfile -Command \"Add-Content -Path \$env:ProgramData\ssh\administrators_authorized_keys -Value '${PUB}'; icacls \$env:ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'\""

echo
echo "Verifying key-only login…"
ssh -i "$KEY" -o BatchMode=yes -o IdentitiesOnly=yes "$USERHOST" "echo KEY-LOGIN-OK && ver" && echo "SUCCESS" || echo "FAILED — tell the agent"
