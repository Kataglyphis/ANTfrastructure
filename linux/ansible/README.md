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
| `pi-2` | older Raspberry Pi, Debian 13 | SSH |
| `mintberrycrunch` | riscv64 SoC, Ubuntu 26.04 | SSH |

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
| `playbooks/update.yml` | per host: apt safe-upgrade + autoremove, then (host_vars flags) container-stack update, nerdctl drift report, venv upgrade; reboot only when required |
| `playbooks/bootstrap-fleet.yml` | one-time per new host: passwordless sudo for the ansible user |
| `playbooks/schedule.yml` | installs the weekly systemd timer on pi-1 |
| `playbooks/ping.yml` | lane proof — reach every inventorized host |

**Beyond apt** — per host, set in gitignored `host_vars/<host>.yml`
(template: `host_vars/pi-2.yml.example`):

| Flag | Effect |
| --- | --- |
| `managed_compose_projects` | `nerdctl compose pull` + `up -d --force-recreate` per file — updates the HA/glances containers (force-recreate is REQUIRED under nerdctl; the stack bounces weekly) |
| `report_nerdctl_upstream` | report-only: installed nerdctl vs latest GitHub release. The upgrade itself stays deliberate — `NERDCTL_INSTALL_CONFIRM=1 linux/host-config/install-nerdctl-full.sh` (it stops both containerd lanes and bounces every container) |
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
so a host that was off catches up on boot. `playbooks/schedule.yml` installs
and arms them. Logs: `journalctl --user -u
ansible-update.service`. To move the checkout, re-run `schedule.yml` after —
the units hardcode `%h/ANTfrastructure/linux/ansible`.

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

## Layout

| Path | What |
| --- | --- |
| `ansible.cfg` | Inventory path, strict host-key checking, ssh_config wiring |
| `ssh_config` | Deploy key + known_hosts for remote hosts |
| `inventory/hosts.yml` | The fleet |
| `playbooks/` | What to run |

## Secrets for remote hosts

```bash
ssh-keygen -t ed25519 -f .ssh/id_ed25519     # distribute the .pub to the fleet
ssh-keyscan <host> >> .ssh/known_hosts
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
