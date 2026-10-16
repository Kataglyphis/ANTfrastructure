#!/usr/bin/env bash
# The weekly update's status.json, which Home Assistant shows, says what the run's log says; see linux/ansible/README.md#the-run-status-in-home-assistant
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
STATUS="${TESTS_DIR}/../../ansible/scripts/ansible_run_status.py"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# status <log> <rc> <out>: one run, the way run-update.sh calls it.
status() {
  python3 "${STATUS}" --log "$1" --rc "$2" --playbook playbooks/update.yml \
    --started 2026-10-18T04:30:00+02:00 --finished 2026-10-18T04:41:40+02:00 \
    --next-run "Sun 2026-10-25 04:49:38 CET" --out "$3"
}
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {}, {"d": d}))' "$1" "$2"; }

# recap <host> <ok> <changed> <unreachable> <failed> <skipped> <rescued> <ignored>: one PLAY RECAP line, as ansible pads it.
recap() {
  printf '%-26s : ok=%-4s changed=%-4s unreachable=%-4s failed=%-4s skipped=%-4s rescued=%-4s ignored=%s\n' "$@"
}
{
  printf 'TASK [Apply available updates] ***\nchanged: [pi-2]\nPLAY RECAP ***\n'
  recap pi-1 12 0 0 0 9 0 0
  recap pi-2 14 2 0 0 7 0 0
} > "${_work}/green.log"

t_case "a green run: result ok, each host with its counts, no notes"
status "${_work}/green.log" 0 "${_work}/green.json"
t_assert_eq "ok" "$(field "${_work}/green.json" 'd["result"]')"
t_assert_eq "2" "$(field "${_work}/green.json" 'd["hosts_total"]')"
t_assert_eq "pi-1:ok pi-2:changed" "$(field "${_work}/green.json" '" ".join(h["name"]+":"+h["status"] for h in d["hosts"])')"
t_assert_eq "14" "$(field "${_work}/green.json" 'd["hosts"][1]["ok"]')"
t_assert_eq "[]" "$(field "${_work}/green.json" 'd["notes"]')"
t_assert_eq "700" "$(field "${_work}/green.json" 'd["duration_s"]')"
t_assert_eq "Sun 2026-10-25 04:49:38 CET" "$(field "${_work}/green.json" 'd["next_run"]')"

{
  printf '    "msg": "GARAGE: v3.0.0 is out, installed v2.4.1; not installed automatically"\n'
  printf '    "msg": "TOOLCHAIN: installed nerdctl 2.1.0, upstream 2.2.0 — UPDATE AVAILABLE"\n'
  printf 'fatal: [ghost]: FAILED! => {"changed": false, "msg": "ghost did not answer, so it was not updated"}\n'
  printf 'PLAY RECAP ***\n'
  recap ghost 2 1 0 1 0 0 1
  recap pi-1 12 0 0 0 9 0 0
  recap srv-1 14 6 0 0 1 1 0
} > "${_work}/red.log"

t_case "a host that did not answer: the run is failed, the host too, and every note is named once"
status "${_work}/red.log" 2 "${_work}/red.json"
t_assert_eq "failed" "$(field "${_work}/red.json" 'd["result"]')"
t_assert_eq "1" "$(field "${_work}/red.json" 'd["hosts_failed"]')"
t_assert_eq "ghost:failed pi-1:ok srv-1:changed" "$(field "${_work}/red.json" '" ".join(h["name"]+":"+h["status"] for h in d["hosts"])')"
t_assert_eq "3" "$(field "${_work}/red.json" 'len(d["notes"])')"
t_assert_contains "$(field "${_work}/red.json" 'd["notes"][0]')" "GARAGE: v3.0.0 is out"
t_assert_contains "$(field "${_work}/red.json" 'd["notes"][2]')" "ghost did not answer, so it was not updated"

t_case "a rescued task is no failure: the Garage rollback leaves srv-1 changed, not failed"
t_assert_eq "1" "$(field "${_work}/red.json" 'd["hosts"][2]["rescued"]')"

t_case "a run without a recap is failed even with rc 0 (ansible stopped before it could report)"
printf 'ERROR! the playbook could not be read\n' > "${_work}/crash.log"
status "${_work}/crash.log" 0 "${_work}/crash.json"
t_assert_eq "failed" "$(field "${_work}/crash.json" 'd["result"]')"
t_assert_eq "0" "$(field "${_work}/crash.json" 'd["hosts_total"]')"

t_case "the history keeps the newest runs first and at most ten"
for _ in $(seq 1 11); do status "${_work}/green.log" 0 "${_work}/many.json"; done
status "${_work}/red.log" 2 "${_work}/many.json"
t_assert_eq "10" "$(field "${_work}/many.json" 'len(d["history"])')"
t_assert_eq "failed ok" "$(field "${_work}/many.json" '" ".join(r["result"] for r in d["history"][:2])')"

t_case "a long log keeps only its end, small enough for Home Assistant's recorder"
for i in $(seq 1 5000); do printf 'TASK [step %d] %s\n' "${i}" "$(printf 'x%.0s' $(seq 1 40))"; done > "${_work}/long.log"
cat "${_work}/green.log" >> "${_work}/long.log"
status "${_work}/long.log" 0 "${_work}/long.json"
t_assert_ok test "$(field "${_work}/long.json" 'len(d["log_tail"])')" -le 6000
t_assert_contains "$(field "${_work}/long.json" 'd["log_tail"]')" "PLAY RECAP"
t_assert_ok test "$(wc -c < "${_work}/long.json")" -lt 12000

t_summary
