# Ansible on pi-1 — pip install per the official docs

Ansible is installed **on the host via pip in a venv**, following the
[official installation guide](https://docs.ansible.com/projects/ansible/latest/installation_guide/intro_installation.html).
It is NOT containerised: the owner directive (2026-10-02) is pip on the host,
and a container runner was evaluated and dropped. The playbooks, inventory and
SSH config for this machine's fleet live here.

## The fleet

| Host | What it is | Connection |
| --- | --- | --- |
| `pi-1` | Raspberry Pi 5 (control node, Home Assistant) | local |
| `pi-2` | Raspberry Pi 3, Debian 13 | SSH |
| `tabblscatcam` | Raspberry Pi 5 (cat cam), Debian 13 | SSH |
| `pi-3` | Raspberry Pi 4, Debian 13 | SSH |
| `srv-1` | Ubuntu 26.04 server, reached over WireGuard | SSH (as root) |
| `mintberrycrunch` | SpacemiT K3 (riscv-class SBC), Ubuntu 26.04 | SSH |
| `summy-server` | Windows 11 ARM Pro | SSH + PowerShell (`ansible.windows`) |

## What is installed (2026-10-02)

| Item | Value |
| --- | --- |
| venv | `~/venvs/ansible` (Python 3.13.5, host interpreter) |
| package | `ansible` **community** package 14.4.0 — core 2.21.4 + bundled collections |
| executables | `~/venvs/ansible/bin/{ansible,ansible-playbook,ansible-vault,…}` |
| collections dir | `~/.ansible/collections` (ansible-galaxy default) |
| config discovery | `ansible.cfg` in this directory — **run ansible from here** |

Install commands (the docs' venv path, works because `python3-venv` is present):

```bash
python3 -m venv ~/venvs/ansible
source ~/venvs/ansible/bin/activate
python3 -m pip install --upgrade pip
python3 -m pip install ansible          # community package, NOT bare ansible-core
ansible --version                       # verify
```

Upgrades: `python3 -m pip install --upgrade ansible` inside the venv. Do NOT
use `--break-system-packages` or `--user` on the system pip — Ubuntu 26.04 is
PEP 668 externally-managed, and the venv exists precisely to avoid that.

## What gets updated, and how

**Via apt** (every host): kernel + GPU firmware (the `raspberrypi-kernel`,
`linux-image-rpi-*`, `raspi-firmware` packages), security libraries, the
desktop stack — everything apt tracks, in `upgrade --with-new-pkgs` mode:
new dependencies yes, package removals never. Config files are never
overwritten by package defaults (`--force-confdef --force-confold`).

**Bootloader EEPROM** (Pi 4/5 only — pi-2 has none): apt delivers new
bootloader images, the playbook queries `rpi-eeprom-update` (exit 1 =
available), stages it (`-a`, the bootrom flashes during the reboot) and
treats it as a reboot trigger. The boot-time `rpi-eeprom-update.service`
also exists as a backstop, but nothing else guarantees a reboot ever
happens — that is this playbook's job.

**Containers** (`managed_compose_projects`): the HA/glances images are
pulled and the stack recreated weekly. The two tasks report `changed` on
EVERY run: `--force-recreate` is required under nerdctl (it keeps a running
container on its old image after a pull), and it bounces the stack by
design — a few seconds at Sunday 04:30, not a false positive.

**Toolchain** (`report_nerdctl_upstream`): report-only, see table above.
**Venv** (`manage_ansible_venv`): runs last.

## Usage

```bash
cd linux/ansible
~/venvs/ansible/bin/ansible-playbook playbooks/ping.yml
```

Or activate the venv first (`source ~/venvs/ansible/bin/activate`). Running
from this directory is required — `ansible.cfg`, `ssh_config` and the
`.ssh/` key paths are all relative.

## The fleet, and keeping it up to date

| Playbook | What it does |
| --- | --- |
| `playbooks/update.yml` | first pings every host and skips one that does not answer; then per host: apt safe-upgrade + autoremove, then (host_vars flags) container-stack update, nerdctl drift report, Tasmota device report, venv upgrade; reboot only when required |
| `playbooks/update-tasmota.yml` | stock Tasmota plugs: REAL gated updates — the version comparison is OURS (the native `Upgrade 1` re-flashes even at the same version, probed live); flash + wait + MQTT health only when the release differs |
| `playbooks/update-windows.yml` | summy-server: Windows Update via PSWindowsUpdate (`-AcceptAll -IgnoreReboot`), reboot inline only when pending |
| `playbooks/update-bitshake.yml` | on-demand: the bitShake SmartMeterReader firmware + SMR app (HTTP-driven, never scheduled — a failed flash kills the energy data). Procedure + traps: [HA README § bitShake](../homeassistant/README.md#the-bitshake-smartmeterreader-firmware-updates) |
| `playbooks/backup.yml` | weekly: copies the Nextcloud AIO Borg repo, Home Assistant's newest backup and each host's secrets to the NAS ([Backups to the NAS](#backups-to-the-nas)) |
| `playbooks/bootstrap-fleet.yml` | one-time per new host: passwordless sudo for the ansible user |
| `playbooks/schedule.yml` | installs the weekly update and backup timers on pi-1 |
| `playbooks/ping.yml` | lane proof — reach every inventorized host |

**Beyond apt** — per host, set in gitignored `host_vars/<host>.yml`
(template: `host_vars/pi-2.yml.example`):

| Flag | Effect |
| --- | --- |
| `managed_compose_projects` | `nerdctl compose pull` + `up -d --force-recreate` per file — updates the HA/glances containers (force-recreate is REQUIRED under nerdctl; the stack bounces weekly) |
| `report_nerdctl_upstream` | report-only: installed nerdctl vs latest GitHub release. The upgrade itself stays deliberate — `NERDCTL_INSTALL_CONFIRM=1 linux/host-config/install-nerdctl-full.sh` (it stops both containerd lanes and bounces every container) |
| `update_tasmota` | the stock Tasmota ESP8266 plugs (addresses in `stock_tasmota_devices`): flash via the official OTA channel ONLY when the release version differs, then wait for the reboot and assert MQTT health (a plug that lost its broker host silently stops feeding HA — the `.128` lesson) |
| `update_bitshake` | the bitShake SmartMeterReader: the update-bitshake playbook with its version gate (only flashes when the manifest differs), magic-byte check and post-flash health gate |
| `manage_windows_updates` | runs `update-windows.yml` on the `windows` group — Windows Update over OpenSSH via PSWindowsUpdate; a failing Windows run is surfaced but does not fail the Pi lane |
| `update_garage` | the Garage S3 store, a binary outside apt (`tasks/update-garage.yml`): the newest stable release of the installed major version, from Garage's release list and download server. Before the swap a metadata snapshot; after it Garage must report itself healthy, on the new version, with its S3 port open, or the previous binary goes back and the run goes on. A new major is only reported (`GARAGE: v… is out`), since Garage needs its own migration between majors. Garage publishes no checksums, so the check is that the download reports the version it was fetched as. Paths and port: `garage_binary`, `garage_config_file`, `garage_systemd_unit`, `garage_s3_api_port` |
| `manage_ansible_venv` | `pip install -U ansible` into `~/venvs/ansible`, runs LAST so a broken release cannot take down the run that installs it |

**Adding a new host** (the `pi-2` and `mintberrycrunch` slots were filled
this way; any apt-based Linux works, not only Pis):

```bash
cd linux/ansible
# 1. inventory: add the host key, values in gitignored host_vars:
cp inventory/host_vars/pi-2.yml.example inventory/host_vars/<name>.yml  # fill in
# 2. hand out the key:
ssh-copy-id -i .ssh/id_ed25519.pub <user>@<address>
ssh-keyscan -t ed25519 <address> >> .ssh/known_hosts
# 2. grant unattended sudo (once, with the become password):
~/venvs/ansible/bin/ansible-playbook playbooks/bootstrap-fleet.yml --limit <name> -K
# 3. prove it:
~/venvs/ansible/bin/ansible-playbook playbooks/ping.yml
```

**The schedule**: `systemd/ansible-update.{service,timer}` are user units on
pi-1 (linger is enabled — the rootless containerd stack requires it).
They fire **Sundays 04:30 Europe/Berlin + 30 min jitter**, `Persistent=true`
so a host that was off catches up on boot. `systemd/ansible-backup.{service,timer}`
fire **Saturdays 07:00 + 15 min jitter** the same way. `playbooks/schedule.yml` installs
and arms all four. The service runs `scripts/run-update.sh`, which runs
`playbooks/update.yml` and keeps what it printed (next section). To move the checkout, re-run
`schedule.yml` after — the units hardcode `%h/ANTfrastructure/linux/ansible`.

## The run status in Home Assistant

Since 2026-10-16 every scheduled run leaves a record, and Home Assistant shows it on an
**Ansible** page in its sidebar (`linux/homeassistant/README.md`, *The Ansible page*).

| Where | What |
| --- | --- |
| `~/.local/state/ansible-update/runs/<date>-<time>.log` on pi-1 | each run's full output, the newest 20 kept. The user journal on pi-1 is volatile, so `journalctl --user -u ansible-update.service` only reaches back to the last boot |
| `linux/homeassistant/config/ansible/status.json` (gitignored) | the last run: result, exit code, start, end, duration, the timer's next date, every host's PLAY RECAP counts and a one-word status (`ok`, `changed`, `failed`, `unreachable`), the notes the playbook prints (`GARAGE:`, `TOOLCHAIN:`, a host that did not answer), the 10 slowest tasks with their seconds, the last 10 runs, and the log's last 60 lines |

The weekly backup writes the same pair, to `~/.local/state/ansible-backup/runs/` and
`config/ansible/backup-status.json`, and its page is the Ansible page's **Backup** view.

`scripts/run-update.sh [playbook]` writes both: it runs the playbook (default
`playbooks/update.yml`) with its output `tee`d to the journal and the log file and with
`ansible.posix.profile_tasks` on, which ends the log with the 10 slowest tasks
(`PROFILE_TASKS_TASK_OUTPUT_LIMIT`; the first real run took 31 min 49 s, 2026-10-16), then
`scripts/ansible_run_status.py` reads the log and writes `status.json` beside the previous one,
whose history it carries on. A run without a PLAY RECAP counts as failed whatever its exit code,
because ansible stopped before it could report. To refresh the page by hand without updating
anything, `scripts/run-update.sh playbooks/ping.yml`. Overrides, all optional:
`ANSIBLE_UPDATE_STATE` (the log directory's parent), `ANSIBLE_UPDATE_STATUS_DIR`,
`ANSIBLE_UPDATE_KEEP_RUNS`, and `ANSIBLE_UPDATE_STATUS_NAME` and `ANSIBLE_UPDATE_TIMER`, which
`ansible-backup.service` sets. Runs take a lock (`~/.local/state/ansible-run.lock`) and wait for
each other, so a backup that catches up at boot never copies from a host the update is rebooting.
`linux/scripts/tests/test-ansible-run-status.sh` checks the status
against sample logs: a green run with its slowest tasks, a host that did not answer with Garage and toolchain notes, a
rescued task, a run that crashed before its recap, the backup's notes, the history's length and
the size of the log's end.

**Nothing of it is published.** The status and the logs name hosts and print what the hosts
answered, so `status.json` sits in a gitignored directory and the logs outside the repository.
The tracked pieces (`run-update.sh`, `ansible_run_status.py`, the Home Assistant package and
dashboard) carry no address and no secret.

**A host that is off does not stop the run** (2026-10-16). Under `serial: 1` every host is its own
batch, and Ansible ends a play when a whole batch fails (`playbook_executor.py`): one camera
switched off on a Sunday used to cost every host after it, pi-1 included, its update. `update.yml`
now pings the fleet first, updates only the hosts that answered (`fleet:&update_reachable`, in
inventory order), and fails at the end once per host that did not, so the journal still names it.
A host that answers but fails during its update still stops the run, as before.

**Reboot policy — two traps, both load-bearing:**

- **pi-1 reboots LAST and DELAYED** (`shutdown -r +2`). It is the
  control node: an inline reboot would kill the running playbook mid-report.
  Inventory order is load-bearing for this — keep pi-1 last in `fleet`.
- **The kernel-staleness check compares within the running kernel's FLAVOR.**
  This host runs `v8-16k+` while `ls -1v /lib/modules | tail -1` answers
  `v8-rt+` — a naive cross-flavor comparison would report "stale" forever
  and reboot-loop the Pi every Sunday. Debian Pis have no
  `/var/run/reboot-required` marker; Ubuntu hosts (mintberrycrunch) DO write
  it, and it is the primary reboot signal there — Ubuntu kernel packages
  change the ABI suffix, which the flavor match alone would miss.

Remote hosts reboot inline (`ansible.builtin.reboot` + wait); `serial: 1`
means never two hosts down at once — pi-1 carries Home Assistant.

## Backups to the NAS

Since 2026-10-26, `playbooks/backup.yml` copies what git does not hold to the QNAP NAS every
Saturday. pi-1 is the hub: it mounts the NAS share over SMB for the run only, pulls each source
onto it, and unmounts it again.

| Source | On the NAS share | Encrypted by | Kept |
| --- | --- | --- | --- |
| Nextcloud AIO's Borg repo on srv-1 (`/root/nextcloud_aio/borg`, ~39 GB) | `nextcloud/srv-1/borg/`, a mirror | Borg (the passphrase is in srv-1's secrets bundle) | by the QTS snapshots |
| Home Assistant's newest backup (`config/backups/*.tar`) | `homeassistant/` | Home Assistant's backup key | the newest 8 |
| each host's `backup_secret_paths` | `secrets/<host>/<host>-<stamp>.tar.gz.age` | `age`, for `backup_age_recipients` | the newest 12 |

**Why pi-1 pulls**: srv-1 is on the internet and gets no NAS credential; QTS allows SSH only
for administrators, while SMB takes a user who can see one share; and pi-1 already logs in to
srv-1 as root for the update.

**What fails the run**, each one loudly and after every other source was copied:

- **Nextcloud.** The host does not answer (down, or its SSH host key changed); the other
  sources still go and the share is still unmounted. AIO is writing its repo (`lock.roster`),
  or someone else holds `aio-lockfile`.
  The source is not a Borg repo, or its repo id is not the NAS copy's: a recreated repo mirrored
  with `--delete` would replace the copy's whole history (`-e backup_nextcloud_accept_new_repo=true`
  for a deliberate one). The copy still differs from the locked repo after the mirror, file
  times included: the share is mounted with `closetimeo=0`, because the kernel's deferred close
  lets the NAS stamp every file with its close time. AIO's
  newest archive is older than `backup_max_age_hours` (72).
- **Home Assistant.** The newest archive is not encrypted (it carries every token in `.storage`),
  is older than 72 h, or its NAS copy's sha256 differs.
- **Secrets.** A path is missing, or what `age` wrote is not an age file.
- **The target.** The NAS credentials file is not root's with mode 0600, or the target is not a
  CIFS mount, so a failed mount never fills the Pi's own disk.

**`aio-lockfile` is AIO's off switch.** While it exists, AIO's `backupscript.sh` skips every
daily backup ("Not continuing because aio-lockfile exists"), as AIO's own sync recipe intends.
The run writes `ansible-backup <stamp> <hub>` into it and removes it in an `always:`. A run that
was killed leaves it behind; the next run takes it over, reports it and removes it. A lockfile
without that marker belongs to someone else and stops the copy.

**The NAS copy of the repo is for restoring only.** Borg's FAQ: two repos with one id must never
both be written, because that is data loss and AES counter reuse. Never point a running AIO at
the NAS copy while srv-1's AIO still writes the original.

**The snapshots are the history.** The repo is a mirror and the share is writable by pi-1's user,
so only the QTS snapshots protect against a damaged repo mirrored over a good copy, or a hub that
was taken over. That user cannot delete a snapshot.

### One-time setup

1. **The NAS (QTS web UI).** Create a shared folder on a thin or thick volume (a static volume
   takes no snapshots) and a user outside the administrators group with read/write on it. Here
   they are `AutoBackups` and `Auto_Backups`; the user also reads the shares open to everyone
   (`Public`, `Multimedia`), which the owner accepted. Snapshots: Storage & Snapshots →
   Storage/Snapshots → the volume → Snapshot → Snapshot Manager → Schedule Snapshot, weekly on
   Sunday after the Saturday run, retention a fixed number of 8. QTS snapshots the whole volume.
2. **The credentials on pi-1**, root's alone (the run checks), then a test mount that writes:
   ```bash
   sudo install -d -m 700 /etc/ansible-backup
   sudo install -m 600 /dev/null /etc/ansible-backup/nas.credentials
   sudoedit /etc/ansible-backup/nas.credentials   # two lines: username=..., password=...
   sudo mount -t cifs //192.168.188.135/AutoBackups /mnt/nas-backup \
     -o credentials=/etc/ansible-backup/nas.credentials,uid=$(id -u),gid=$(id -g)
   touch /mnt/nas-backup/.t && rm /mnt/nas-backup/.t && sudo umount /mnt/nas-backup
   ```
   `mount error(2)` with `BAD_NETWORK_NAME` in `dmesg` is a share name the NAS does not have; a
   wrong password fails earlier, with `error(13)`. Put the share into `backup_nas_share`.
3. **The age key**: `age-keygen` with no `-o` prints the key and writes no file, so pi-1 is fine.
   Copy all three lines into the password manager and put the `age1...` public key into
   `backup_age_recipients` in `host_vars/pi-1.yml`. The `AGE-SECRET-KEY-...` line goes nowhere
   else: that one key opens every bundle, and the bundles hold the Borg passphrase and the Home
   Assistant backup key.
4. **Home Assistant encrypts its own backups**: Settings → System → Backups → Backup settings →
   Locations → *This system* → encryption on, and its emergency kit (the backup key) into the
   password manager. Since 2025.2 encryption is chosen per location, and local was off. Older
   archives stay unencrypted and are never copied; Home Assistant's retention of 3 drops them.
5. **Arm it** with `~/venvs/ansible/bin/ansible-playbook playbooks/schedule.yml`, and start the
   first copy by hand: `systemctl --user start ansible-backup.service`. It moves the whole repo
   over WireGuard; later runs move only new Borg segments.

The host_vars keys: `backup_nas_share`, `backup_nas_credentials`, `backup_nas_mount_opts` (extra
CIFS options, e.g. `seal`), `backup_age_recipients`, `backup_homeassistant` and
`backup_homeassistant_dir`, `backup_secret_paths`, `backup_nextcloud_aio_repo` and
`backup_nextcloud_aio_archives_list`, `backup_max_age_hours`, `backup_homeassistant_keep`,
`backup_secrets_keep`. The template is `host_vars/pi-2.yml.example`.

### Restoring

- **Nextcloud**: copy `nextcloud/srv-1/borg` (from the share or a snapshot) to the new host,
  start a fresh AIO and choose *Restore former AIO instance from backup* with the folder that
  holds `borg` and the passphrase, `borg_backup_password` in the bundle's `configuration.json`.
  That is AIO's own migration path.
- **Home Assistant**: onboard a fresh instance, choose *Restore from backup*, upload the `.tar`
  and give it the backup key, which is in the password manager and in the bundle's
  `.storage/backup`.
- **Secrets**: `age -d -i backup-key.txt <host>-<stamp>.tar.gz.age | tar -xzf - -C <dir>`. The
  paths inside are the absolute ones without their leading `/`.

### Tests

`linux/scripts/tests/test-ansible-backup.sh` covers the two helpers with a fake `age`: the newest
Home Assistant archive by its own date, its encryption and its age; a bundle that never holds
plaintext and leaves nothing behind when a path is missing or `age` misbehaves. Seven
`mutations.json` entries prove those checks can fail.

`tests/test-backup-playbook.sh` runs the playbook itself against a local fake AIO host, a fake
Home Assistant and a temporary directory standing in for the NAS, with a real `age` key. It needs
the venv and `age`, so it is not one of the auto-discovered suites: run it by hand after a change
to the playbook. It covers the mirror, deletions, retention, `lock.roster`, a foreign and a stale
`aio-lockfile`, a recreated repo, an AIO that stopped backing up, an unreachable AIO host and an
unencrypted archive.

Not covered by any test: the CIFS mount and the QTS snapshots, which live on the NAS, and a
restore. Restore one archive of each kind by hand once a quarter.

## Layout

| Path | What |
| --- | --- |
| `ansible.cfg` | Inventory path, strict host-key checking, ssh_config wiring |
| `ssh_config` | Deploy key + known_hosts for remote hosts |
| `inventory/hosts.yml` | The fleet |
| `playbooks/` | What to run |
| `tasks/` | Task files the playbooks include (Garage, the backup's sources) |
| `scripts/` | The run wrapper, its status writer and the backup's helpers |
| `systemd/` | The update and backup timers |
| `tests/` | `test-backup-playbook.sh`, run by hand |

## Secrets for remote hosts

```bash
ssh-keygen -t ed25519 -f .ssh/id_ed25519     # distribute the .pub to the fleet
ssh-keyscan <host> >> .ssh/known_hosts
```

A host whose key changed fails with `REMOTE HOST IDENTIFICATION HAS CHANGED`. Replace the line
only after the host's own console shows the fingerprint the network now sends:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub              # on the host itself
ssh-keyscan -t ed25519 <ip> | ssh-keygen -lf -                 # here: must match
ssh-keygen -f .ssh/known_hosts -R <ip> && ssh-keyscan -t ed25519 <ip> >> .ssh/known_hosts
```

Vault-encrypted vars: `ansible-vault create secret-vars.yml`, then run with
`--ask-vault-pass` or `--vault-password-file`. `.ssh/` and retry files are
gitignored.

## Notes worth keeping

- **`ansible` vs `ansible-core`**: the community package (installed here)
  bundles ~90 maintained collections; bare `ansible-core` is just the engine
  plus `ansible.builtin`. Install extra collections into `~/.ansible/collections`
  with `ansible-galaxy collection install <name>`.
- **Upgrade cadence**: the community package follows the
  [Ansible release cycle](https://docs.ansible.com/ansible-community-docs/latest/community/8_release_and_maintenance.html)
  (2 majors per year, e.g. core 2.20/2.21 in the 14.x series); core minors
  land as needed.
- **Devel docs**: upstream lives at
  [github.com/ansible/ansible](https://github.com/ansible/ansible) — the repo
  this stack tracks. It is the engine source, not the thing to install.
- **PyYAML here ships with the C ext** (`pyyaml 6.0.3 (with libyaml)`) — aarch64
  wheels resolved cleanly, no toolchain needed (unlike the riscv64 case).
- The earlier container approach was dropped for this host, but the finding
  is worth keeping: the official EE images
  (`ghcr.io/ansible-community/community-ee-*`) are **amd64-only** — unusable
  on an aarch64 Pi.
