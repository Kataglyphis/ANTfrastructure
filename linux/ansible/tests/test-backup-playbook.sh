#!/usr/bin/env bash
# Runs playbooks/backup.yml for real against local fakes: needs the ansible venv and age, so it is run by hand; see ../README.md#backups-to-the-nas
set -u
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ANSIBLE_DIR}/../scripts/tests/test-harness.sh"
PLAYBOOK_BIN="${ANSIBLE_PLAYBOOK:-${HOME}/venvs/ansible/bin/ansible-playbook}"
t_skip_unless "ansible-playbook" test -x "${PLAYBOOK_BIN}"
t_skip_unless "age" command -v age-keygen

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT
repo="${_work}/aio/borg" ha="${_work}/ha" nas="${_work}/nas" secret="${_work}/secret"
mkdir -p "${repo}/data/0" "${ha}" "${nas}" "${secret}"
age-keygen -o "${_work}/key.txt" 2> /dev/null
recipient="$(age-keygen -y "${_work}/key.txt")"

repo_config() { printf '[repository]\nversion = 1\nid = %s\n' "$1" > "${repo}/config"; }
repo_config "$(printf 'a%.0s' $(seq 64))"
head -c 4096 /dev/urandom > "${repo}/data/0/1"
echo "SECRET-WG-KEY" > "${secret}/wg0.conf"
# archive_list <hours ago>: AIO's list, its last line dated in UTC.
archive_list() { echo "20261026_040135-nextcloud-aio,$(date -u -d "-$1 hours" '+%Y-%m-%d %H:%M:%S')" > "${_work}/aio/list"; }
archive_list 2
# ha_archive <name> <hours ago> <protected>
ha_archive() {
  python3 - "${ha}/$1" "$(date -d "-$2 hours" --iso-8601=seconds)" "$3" <<'PY'
import io
import json
import sys
import tarfile

meta = json.dumps({"name": sys.argv[1], "date": sys.argv[2], "protected": sys.argv[3] == "true"}).encode()
with tarfile.open(sys.argv[1], "w") as tar:
    info = tarfile.TarInfo("./backup.json")
    info.size = len(meta)
    tar.addfile(info, io.BytesIO(meta))
PY
}
ha_archive old.tar 30 true
ha_archive new.tar 3 true

cat > "${_work}/hosts.yml" <<EOF
all:
  hosts:
    hub:
      ansible_connection: local
      backup_root: ${nas}
      backup_age_recipients: [${recipient}]
      backup_homeassistant: true
      backup_homeassistant_dir: ${ha}
      backup_homeassistant_keep: 1
      backup_secret_paths: [${secret}/wg0.conf]
    aio:
      ansible_connection: local
      backup_nextcloud_aio_repo: ${repo}
      backup_nextcloud_aio_archives_list: ${_work}/aio/list
EOF
run() {
  (cd "${ANSIBLE_DIR}" && "${PLAYBOOK_BIN}" -i "${_work}/hosts.yml" -e backup_hub=hub playbooks/backup.yml "$@") > "${_work}/run.log" 2>&1
}
copy="${nas}/nextcloud/aio/borg"

t_case "a green run mirrors the repo, copies the newest encrypted archive and bundles the secrets"
t_assert_ok run
t_assert_ok cmp "${repo}/data/0/1" "${copy}/data/0/1"
t_assert_fails test -e "${repo}/aio-lockfile"
t_assert_eq "new.tar" "$(ls "${nas}/homeassistant")"
bundle="$(ls "${nas}"/secrets/hub/*.age)"
t_assert_eq "SECRET-WG-KEY" "$(age -d -i "${_work}/key.txt" "${bundle}" | tar -xzOf -)"
t_assert_fails grep -q -e SECRET-WG-KEY "${bundle}"
t_assert_contains "$(cat "${_work}/run.log")" "BACKUP: nextcloud aio: newest archive 20261026_040135-nextcloud-aio"

t_case "the mirror follows deletions, and the NAS keeps only the newest Home Assistant copies"
rm "${repo}/data/0/1"
ha_archive newer.tar 1 true
t_assert_ok run
t_assert_fails test -e "${copy}/data/0/1"
t_assert_eq "newer.tar" "$(ls "${nas}/homeassistant")"

t_case "AIO writing its repo (lock.roster): not copied, the run fails, the other sources still go"
touch "${repo}/lock.roster" "${repo}/data/0/2"
rm "${nas}/homeassistant/newer.tar"
t_assert_fails run
t_assert_fails test -e "${copy}/data/0/2"
t_assert_fails test -e "${repo}/aio-lockfile"
t_assert_eq "newer.tar" "$(ls "${nas}/homeassistant")"
t_assert_contains "$(cat "${_work}/run.log")" "the repo is busy (roster)"
rm "${repo}/lock.roster"

t_case "someone else's aio-lockfile is left alone and stops the copy"
echo "external sync" > "${repo}/aio-lockfile"
t_assert_fails run
t_assert_eq "external sync" "$(cat "${repo}/aio-lockfile")"
t_assert_fails test -e "${copy}/data/0/2"

t_case "a lockfile a killed run of ours left behind is taken over, reported and released"
echo "ansible-backup 20261024-070000 hub" > "${repo}/aio-lockfile"
t_assert_ok run
t_assert_fails test -e "${repo}/aio-lockfile"
t_assert_ok test -e "${copy}/data/0/2"
t_assert_contains "$(cat "${_work}/run.log")" "took over a stale aio-lockfile"

t_case "a recreated repo does not replace the NAS copy's history, unless that is asked for"
repo_config "$(printf 'b%.0s' $(seq 64))"
t_assert_fails run
t_assert_contains "$(cat "${_work}/run.log")" "if it was recreated on purpose"
t_assert_ok run -e backup_nextcloud_accept_new_repo=true
t_assert_fails test -e "${repo}/aio-lockfile"

t_case "an AIO that stopped backing up is copied, then fails the run"
archive_list 100
touch "${repo}/data/0/3"
t_assert_fails run
t_assert_ok test -e "${copy}/data/0/3"
t_assert_contains "$(cat "${_work}/run.log")" "AIO stopped backing up"
archive_list 2

t_case "an unreachable AIO host fails only its own source: the later sources still go"
cat > "${_work}/gone.yml" <<'EOF'
all:
  hosts:
    gone:
      ansible_host: 127.0.0.1
      ansible_port: 1
      backup_nextcloud_aio_repo: /nonexistent
EOF
rm "${nas}/homeassistant/newer.tar"
t_assert_fails run -i "${_work}/gone.yml"
t_assert_eq "newer.tar" "$(ls "${nas}/homeassistant")"
t_assert_contains "$(cat "${_work}/run.log")" "BACKUP: nextcloud gone: unreachable"
t_assert_contains "$(cat "${_work}/run.log")" "1 source(s) failed: nextcloud gone"

t_case "an unencrypted Home Assistant archive stays on the Pi"
ha_archive plain.tar 0 false
t_assert_fails run
t_assert_fails test -e "${nas}/homeassistant/plain.tar"
t_assert_contains "$(cat "${_work}/run.log")" "is not encrypted"

t_summary
