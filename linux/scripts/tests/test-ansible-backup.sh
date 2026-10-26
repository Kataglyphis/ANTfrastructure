#!/usr/bin/env bash
# The weekly NAS backup's two helpers refuse what must not leave a host; see linux/ansible/README.md#backups-to-the-nas
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/test-harness.sh"
SCRIPTS="${TESTS_DIR}/../../ansible/scripts"
NEWEST="${SCRIPTS}/ha_backup_newest.py"
SECRETS="${SCRIPTS}/backup-secrets.sh"

_work="$(mktemp -d)"
trap 'rm -rf "${_work}"' EXIT

# ha_archive <file> <date> <protected: true|false>: an archive shaped like Home Assistant's, backup.json first.
ha_archive() {
  python3 - "$@" <<'PY'
import io
import json
import sys
import tarfile

path, date, protected = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
meta = json.dumps({"version": 2, "name": "Automatic backup", "date": date, "protected": protected,
                   "homeassistant": {"version": "2026.10.4"}}).encode()
with tarfile.open(path, "w") as tar:
    for name, data in (("./backup.json", meta), ("homeassistant.tar.gz", b"payload")):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
PY
}
newest() { python3 "${NEWEST}" --dir "$1" --max-age-hours "$2" --now 2026-10-26T12:00:00+01:00; }
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"; }

ha="${_work}/ha" && mkdir -p "${ha}"
# The name sorts last but the date is older: the choice must follow backup.json, not the file name.
ha_archive "${ha}/Z_backup.tar" 2026-10-24T04:48:15+02:00 true
ha_archive "${ha}/A_backup.tar" 2026-10-26T04:50:58+01:00 true

t_case "Home Assistant: the newest archive by its own date, encrypted and recent, passes"
t_assert_ok newest "${ha}" 72
t_assert_eq "${ha}/A_backup.tar" "$(newest "${ha}" 72 | field file)"
t_assert_eq "True" "$(newest "${ha}" 72 | field protected)"
t_assert_eq "7.2" "$(newest "${ha}" 72 | field age_hours)"

t_case "Home Assistant: an archive older than the limit fails, and says Home Assistant stopped"
t_assert_fails newest "${ha}" 6
t_assert_contains "$(newest "${ha}" 6 2>&1 >/dev/null)" "stopped backing up"

t_case "Home Assistant: an unencrypted newest archive never leaves the Pi"
ha_archive "${ha}/B_backup.tar" 2026-10-26T10:00:00+01:00 false
t_assert_fails newest "${ha}" 72
t_assert_contains "$(newest "${ha}" 72 2>&1 >/dev/null)" "is not encrypted"

t_case "Home Assistant: no archive at all, and an archive without backup.json, fail"
mkdir -p "${_work}/empty"
t_assert_fails newest "${_work}/empty" 72
printf 'not a tar' > "${_work}/empty/broken.tar"
t_assert_fails newest "${_work}/empty" 72

# A fake age writes its header and base64, a fake ssh runs the command here, a fake sudo drops -n.
bin="${_work}/bin" && mkdir -p "${bin}"
cat > "${bin}/age" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  case "$1" in -r) echo "recipient $2" >> "${FAKE_LOG}"; shift 2 ;; -o) out="$2"; shift 2 ;; *) exit 9 ;; esac
done
# FAKE_AGE_PLAIN makes it a broken age that passes its input through.
if [ -n "${FAKE_AGE_PLAIN:-}" ]; then cat > "${out}"; else { echo "age-encryption.org/v1"; base64 -w0; } > "${out}"; fi
SH
cat > "${bin}/ssh" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o|-F) shift 2 ;; *) break ;; esac; done
echo "ssh $1" >> "${FAKE_LOG}"
exec bash -c "$2"
SH
cat > "${bin}/sudo" <<'SH'
#!/usr/bin/env bash
[ "$1" = "-n" ] && shift
echo "sudo $1" >> "${FAKE_LOG}"
exec "$@"
SH
chmod +x "${bin}/age" "${bin}/ssh" "${bin}/sudo"
export FAKE_LOG="${_work}/fake.log"
secrets() { PATH="${bin}:${PATH}" bash "${SECRETS}" "$@"; }

src="${_work}/src" && mkdir -p "${src}/keys"
echo "SENTINEL-PRIVATE-KEY" > "${src}/keys/id"
echo "token" > "${src}/vars.yml"
nas="${_work}/nas" && mkdir -p "${nas}"

t_case "secrets: a bundle of every path, through age, for every recipient, and nothing in plaintext"
: > "${FAKE_LOG}"
out="$(secrets --out "${nas}/a.tar.gz.age" -r age1one -r age1two -- "${src}/keys" "${src}/vars.yml")"
t_assert_contains "${out}" "entries=3"
t_assert_eq "age-encryption.org/v1" "$(head -n 1 "${nas}/a.tar.gz.age")"
t_assert_fails grep -q -e SENTINEL-PRIVATE-KEY "${nas}/a.tar.gz.age"
t_assert_eq "recipient age1one,recipient age1two" "$(paste -sd, "${FAKE_LOG}")"
t_assert_eq "keys/id" "$(tail -n 1 "${nas}/a.tar.gz.age" | base64 -d | tar -tzf - | grep -e 'keys/id$' | sed 's|.*/src/||')"

t_case "secrets: a missing path fails, and leaves neither the bundle nor a partial file"
t_assert_fails secrets --out "${nas}/b.tar.gz.age" -r age1one -- "${src}/keys" "${src}/gone"
t_assert_fails test -e "${nas}/b.tar.gz.age"
t_assert_fails test -e "${nas}/b.tar.gz.age.partial"

t_case "secrets: output that is not an age file is refused, so plaintext never reaches the NAS"
t_assert_fails env FAKE_AGE_PLAIN=1 PATH="${bin}:${PATH}" bash "${SECRETS}" --out "${nas}/p.tar.gz.age" -r age1one -- "${src}/keys"
t_assert_fails test -e "${nas}/p.tar.gz.age"
t_assert_fails test -e "${nas}/p.tar.gz.age.partial"

t_case "secrets: a relative path, no recipient or no path is a usage error"
t_assert_eq "2" "$(t_rc secrets --out "${nas}/c.age" -r age1one -- relative/path)"
t_assert_eq "2" "$(t_rc secrets --out "${nas}/c.age" -- "${src}/keys")"
t_assert_eq "2" "$(t_rc secrets --out "${nas}/c.age" -r age1one)"

t_case "secrets: a remote host's tar runs over ssh, under sudo when the login is not root"
: > "${FAKE_LOG}"
t_assert_ok secrets --out "${nas}/d.tar.gz.age" -r age1one --remote me@host --ssh-config cfg --sudo -- "${src}/vars.yml"
t_assert_eq "recipient age1one,ssh me@host,sudo tar" "$(sort "${FAKE_LOG}" | paste -sd, -)"

t_case "secrets: a remote failure leaves nothing behind"
t_assert_fails secrets --out "${nas}/e.tar.gz.age" -r age1one --remote me@host -- "${src}/gone"
t_assert_fails test -e "${nas}/e.tar.gz.age"

t_summary
