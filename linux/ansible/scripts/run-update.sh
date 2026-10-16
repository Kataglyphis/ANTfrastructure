#!/usr/bin/env bash
# The weekly update's ExecStart: runs the playbook, keeps its log across reboots, and writes the status Home Assistant shows.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "${here}/../.." && pwd)"
playbook="${1:-playbooks/update.yml}"
state="${ANSIBLE_UPDATE_STATE:-${XDG_STATE_HOME:-${HOME}/.local/state}/ansible-update}"
status_dir="${ANSIBLE_UPDATE_STATUS_DIR:-${repo}/linux/homeassistant/config/ansible}"
keep="${ANSIBLE_UPDATE_KEEP_RUNS:-20}"

mkdir -p "${state}/runs" "${status_dir}"
started="$(date -Is)"
log="${state}/runs/$(date +%Y%m%d-%H%M%S).log"
# tee: the journal still gets every line, and the file outlives the volatile journal.
(cd "${here}" && exec "${ANSIBLE_PLAYBOOK:-${HOME}/venvs/ansible/bin/ansible-playbook}" "${playbook}") 2>&1 | tee "${log}"
rc=${PIPESTATUS[0]}

next="$(systemctl --user show ansible-update.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
python3 "${here}/scripts/ansible_run_status.py" --log "${log}" --rc "${rc}" --playbook "${playbook}" \
  --started "${started}" --finished "$(date -Is)" --next-run "${next}" --out "${status_dir}/status.json"

find "${state}/runs" -name '*.log' -printf '%T@ %p\n' | sort -rn | tail -n +"$((keep + 1))" | cut -d' ' -f2- |
  xargs -r rm -f --
exit "${rc}"
