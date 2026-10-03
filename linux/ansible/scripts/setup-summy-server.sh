#!/usr/bin/env bash
# One-time bootstrap for summy-server — run interactively (password prompt).
set -euo pipefail
# This script lives at <repo>/linux/ansible/scripts/ — three levels up is the root.
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
KEY=linux/ansible/.ssh/id_ed25519.pub
USERHOST='jonasheinle@googlemail.com@192.168.188.140'

PUB=$(cat "$KEY")
echo "Installing the deploy key into the ADMINISTRATORS file (password prompt follows)…"
ssh "$USERHOST" "powershell -NoProfile -Command \"Add-Content -Path \$env:ProgramData\ssh\administrators_authorized_keys -Value '${PUB}'; icacls \$env:ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'\""

echo
echo "Verifying key-only login…"
ssh -i linux/ansible/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes "$USERHOST" "echo KEY-LOGIN-OK && ver" && echo "SUCCESS" || echo "FAILED — tell the agent"
