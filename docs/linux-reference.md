# Linux Reference (general)

A working set of general Linux commands — the ones that get looked up, forgotten
and looked up again.

> **Unverified by design** — ordinary Linux commands, not checked against any
> build lane, so they do not carry the authority of
> [Linux Host Setup](linux-host-setup.md). Promotion rules:
> [`INDEX.md`](INDEX.md).

---

## Disk and files

```bash
du -sh .                                          # this directory
sudo du -ah --max-depth 2 . | sort -h             # what is under it
sudo du -ah / --max-depth=2 | sort -hr | head -20 # worst offenders
```

Build-host disk triage, including the WSL caveat and `ncdu`, is in
[Linux Host Setup § Finding what filled the disk](linux-host-setup.md#finding-what-filled-the-disk).

Count what file types a tree contains:

```bash
find ~/somedir -type f | sed -n 's/.*\.//p' | sort | uniq -c | sort -nr
```

Count lines of code, roughly or properly:

```bash
# quick and dirty — counts blank lines and comments too
find /path/to/folder -type f -exec cat {} + | wc -l

# only certain extensions
find /path/to/folder \( -name "*.cpp" -o -name "*.h" \) -print0 | xargs -0 cat | wc -l

# language-aware; excludes comments and blanks
sudo apt install -y cloc
cloc /path/to/folder
```

Copy to or from a remote host:

```bash
scp myfile.txt user@host:/path/on/remote/
scp user@host:/path/to/remote/file ~/Downloads/
scp -r ./localdir/* user@host:/path/on/remote/
```

Unpack a `.tar.xz` into a chosen prefix:

```bash
sudo mkdir -p /opt/target
sudo tar -xf archive.tar.xz -C /opt/target
```

Take ownership of a tree:

```bash
ls -ld somedir
sudo chown -R "$USER":"$USER" somedir
```

## Text and logs

Replace every occurrence in a file, in place:

```bash
sed -i 's/old/new/g' yourfile.json
```

Search a tree:

```bash
grep -r "search_string" /path/to/folder
```

Filter a log by a numeric field — here, only frames slower than 1 FPS:

```bash
grep -oE 'FPS: [0-9]+\.[0-9]+' logfile.log | awk -F' ' '{ if ($2 < 1) print $0 }'
```

Take a column out of a section of a profiling log and rank it:

```bash
awk '/ncalls/{flag=1; next} flag' profile.log | awk '{print $5 " " $NF}' | sort -nr | head -n 40
```

Send output to the terminal *and* a file:

```bash
command 2>&1 | tee -a logfile.txt
```

Mining a failed build log specifically is in
[Build resource monitoring § Mining a build log](build-resource-monitoring.md#mining-a-build-log-for-the-actual-failure).

In `nano`, `Ctrl+_` jumps to a line number.

## Processes and services

```bash
systemctl list-units --type=service --all     # every service, running or not
systemctl status <unit>
journalctl -u <unit> -e
```

Long-running work that must survive a disconnect — `nohup`, `tmux`, and doing it
inside a container — is in
[Rancher Desktop § Long-running work](rancher-desktop-linux-containers.md#long-running-work-detached-containers--tmux).

## Users and permissions

```bash
sudo useradd -m -s /bin/bash newuser
sudo passwd newuser
sudo usermod -aG sudo newuser
```

Give a user a home on a non-default path:

```bash
sudo mkdir -p /srv/data/homes/newuser
sudo chown newuser:somegroup /srv/data/homes/newuser
sudo chmod 770 /srv/data/homes/newuser
```

Allow specific commands without a password prompt (`sudo visudo`):

```
someuser ALL=(ALL) NOPASSWD: /usr/bin/curl, /bin/sh
```

> The entry must match the command **including its arguments** as it will be
> invoked. A bare `/sbin/ethtool` does not cover `/sbin/ethtool -s eth0 wol g`,
> and the prompt comes back with no explanation.

## Networking

Find hosts on a subnet, and check a port:

```bash
sudo nmap -sn 192.168.1.0/24              # who is up
nmap -Pn -p22 192.168.1.50                # is this port reachable
nmap -p 22 --open 192.168.1.0/24          # who has SSH open
```

Something already has the port you want:

```bash
sudo ss -tulnp | grep :8080
sudo netstat -tulpn | grep :8080
sudo lsof -p <pid>
```

Restart networking / renew a lease:

```bash
sudo systemctl restart NetworkManager || sudo systemctl restart dhcpcd
sudo dhclient -v -r eth0 && sudo dhclient -v eth0
```

Container-specific networking failures — UFW dropping forwarded traffic, and
resolver problems inside containers — are in
[Linux Host Setup § B5/B6](linux-host-setup.md#b6-ufw-silently-breaks-container-networking).

### Wake-on-LAN

Enabling it takes three layers agreeing — adapter, OS, firmware — which is why
it so often half-works. Check what the NIC currently reports, then enable magic
packets for this boot:

```bash
sudo ethtool eth0                    # look for "Wake-on: d" (disabled) vs "g" (magic)
sudo ethtool -s eth0 wol g
```

That does not survive a reboot. Persist it with a oneshot unit:

```bash
sudo tee /etc/systemd/system/wol.service >/dev/null <<'UNIT'
[Unit]
Description=Enable Wake-on-LAN
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s eth0 wol g

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl enable --now wol.service
```

On a NetworkManager host, set it on the connection instead — NM otherwise
reapplies its own setting and undoes `ethtool`:

```bash
nmcli connection show
sudo nmcli connection modify "<connection-name>" 802-3-ethernet.wake-on-lan magic
sudo nmcli connection modify "<connection-name>" 802-3-ethernet.auto-negotiate yes
```

Verify the packets actually arrive, from the target while another machine sends:

```bash
sudo tcpdump -i eth0 -n -v -s0 "ether proto 0x0842 or (udp and port 9)"
```

```bash
wakeonlan aa:bb:cc:dd:ee:ff          # from the sending machine
```

If the OS side checks out and it still will not wake, the cause is firmware or
power management — the same three-layer checklist and the CMOS-reset trap are in
[Windows Reference § Wake-on-LAN](windows-reference.md#wake-on-lan), and they
apply to the hardware regardless of OS. On laptop-class hardware also confirm
TLP is not overriding power settings; see
[Linux Host Setup § C3](linux-host-setup.md#c3-stop-the-host-suspending-mid-build).

## SSH

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

Keys and the agent:

```bash
ssh-keygen -t ed25519 -C "you@example.com"
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh-keygen -p -f ~/.ssh/id_ed25519        # change the passphrase
```

**After reflashing a board that keeps its hostname**, the host key changes and
SSH refuses to connect. Drop the stale entry rather than disabling checking:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R myboard
```

## Packages, firmware, kernel

```bash
uname -r                                  # running kernel
sudo snap refresh                         # update snaps
```

Firmware updates through the vendor service:

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

Mirror selection, unattended-upgrade policy and APT pinning are build-host
concerns and live in
[Linux Host Setup § Phase E](linux-host-setup.md#phase-e--package-sources-and-automatic-updates).

## Disks, mounts and swap

```bash
lsblk -d -o NAME,SIZE,MODEL
sudo mount /dev/sda2 /mnt/mydisk
sudo mount -a                             # everything in /etc/fstab
```

A quick swapfile (the SBC/low-memory variants, including zram, are in
[Build parallelism § memory-constrained hosts](build-parallelism-memory-tuning.md#the-other-end-building-on-a-memory-constrained-host)):

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=8192
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Mounting an SMB/CIFS network share

For build artifacts, backups, or a shared cache living on a NAS:

```bash
sudo apt install -y cifs-utils
```

Put the credentials in their own file rather than inline in `/etc/fstab`, which
is world-readable:

```bash
sudo tee /root/.smbcredentials >/dev/null <<'CREDS'
username=<user>
password=<password>
CREDS
sudo chmod 600 /root/.smbcredentials
```

`chmod 600` is the part that matters. A credentials file readable by anyone on
the host defeats the purpose of moving it out of `fstab`.

Then in `/etc/fstab`:

```
//<nas-host>/<share>  /mnt/nas  cifs  credentials=/root/.smbcredentials,uid=1000,gid=1000  0  0
```

```bash
sudo mount -a
findmnt /mnt/nas          # confirm it actually mounted
```

`uid`/`gid` matter because CIFS has no Unix ownership of its own — without them
every file appears owned by root and a non-root build cannot write.

### Mirroring a directory with rsync

```bash
rsync -av --delete \
  --exclude "@Recently-Snapshot" --exclude "@Recycle" \
  /mnt/source/ /mnt/destination/
```

Two things to get right: the **trailing slash** on the source means "the contents
of", without it you get the directory nested one level deeper; and `--delete`
removes anything at the destination that is gone from the source, so a wrong
source path silently empties the target. Dry-run first with `-n`.

## Boot

If `grubx64.efi` is missing from the EFI partition, restore it from install
media before reaching for a full reinstall:

```bash
sudo mount -t vfat /dev/nvme0n1p1 /mnt
sudo cp /cdrom/EFI/BOOT/grubx64.efi /mnt/EFI/ubuntu/
```

Everything else about GRUB — rescue prompt, default entry, one-time boot,
`efibootmgr` — is in
[Linux Host Setup § Boot drops to a GRUB prompt](linux-host-setup.md#boot-drops-to-a-grub-prompt).

## Keyboard layout on a headless box

When a board comes up with the wrong layout and there is no desktop to fix it
in, edit `/etc/default/keyboard`:

```
XKBMODEL="pc105"
XKBLAYOUT="de"
XKBVARIANT=""
XKBOPTIONS=""
```

```bash
sudo dpkg-reconfigure keyboard-configuration
sudo setupcon
sudo systemctl restart console-setup
```

## Media and document conversion

`ffmpeg` recipes are the same on either OS — only the paths differ. The
*capture* side (DirectShow enumeration, `gdigrab` screen recording) is
Windows-specific and lives in
[Windows Reference § Media capture](windows-reference.md#media-capture).

Trim to a fixed length without re-encoding — `-c copy` remuxes, so it is near
instant and lossless, at the cost of cutting only on keyframes:

```bash
ffmpeg -i input.mp4 -t 58 -c copy output.mp4
```

Convert an image, format inferred from the extensions:

```bash
ffmpeg -i "input.jfif" output.png
```

Extract every frame as a numbered still:

```bash
ffmpeg -i input.mp4 frames/frame_%06d.png
```

Repair a phone video with broken metadata — remuxing rewrites the container
without touching the streams:

```bash
ffmpeg -i input.mp4 -c:a copy output.mp4
```

Pre-process a screenshot so OCR can read it. Upscaling first is what makes the
difference on small text; the rest is contrast and denoise:

```bash
ffmpeg -i input.jpg -vf "scale=iw*8:ih*8:flags=lanczos,unsharp=9:9:3.0,eq=contrast=1.8:brightness=0.0,format=gray" output_bw.png
```

Resize while preserving aspect ratio (`-1` derives the other dimension):

```bash
ffmpeg -i input.png -vf "scale=800:-1" -y output.png
```

### OCR a scanned PDF

`ocrmypdf` adds a searchable text layer to a scan without altering the page
images. It needs the OCR engine and PDF tooling from the distro, plus a language
pack per language you expect:

```bash
sudo apt update
sudo apt install -y tesseract-ocr poppler-utils pandoc ghostscript
sudo apt install -y tesseract-ocr-deu        # one per extra language

uv venv
uv pip install ocrmypdf
```

```bash
ocrmypdf -l deu+eng input.pdf output.pdf
```

Without the matching `tesseract-ocr-<lang>` package the run fails outright
rather than falling back to English, which is the usual first surprise.

## Remote desktop on a headless box

Two approaches. Pick one and stay with it — running both leaves two RDP servers
competing for port 3389.

| | `gnome-remote-desktop` | `xrdp` + GNOME Flashback |
|---|---|---|
| Session type | Wayland, native | X11 |
| Extra desktop needed | no | yes (Flashback) |
| Config | `grdctl` | edit `startwm.sh` |
| Use when | Ubuntu 23.10+ with GNOME | GNOME Shell will not run, or no GNOME at all |

Both listen on TCP **3389**.

### Option A — `gnome-remote-desktop` (preferred on modern Ubuntu)

Since Ubuntu 23.10 GNOME ships its own RDP server. It runs under Wayland, uses
PipeWire for the framebuffer, and needs no substitute desktop environment.

It has two modes, and picking the wrong one is the usual first mistake:

- **System (headless)** — a systemd *system* service, reachable even with nobody
  logged in locally. This is what you want on a box you dial into. `grdctl --system`.
- **User (screen sharing)** — shares the logged-in user's live session, so
  someone must be logged in at the machine. `grdctl` with no `--system`.

```bash
sudo apt install -y gnome-remote-desktop
sudo grdctl --system rdp enable
```

Credentials are **independent of the Linux login** — these are RDP-only:

```bash
sudo grdctl --system rdp set-credentials <rdp-user> <rdp-password>
```

RDP requires TLS, so generate a certificate. A self-signed one is fine for a
LAN or a tunnel:

```bash
sudo mkdir -p /etc/gnome-remote-desktop
sudo openssl req -new -newkey rsa:4096 -days 720 -nodes -x509 \
  -subj "/C=DE/ST=NA/L=NA/O=NA/CN=gnome" \
  -out /etc/gnome-remote-desktop/rdp-tls.crt \
  -keyout /etc/gnome-remote-desktop/rdp-tls.key

sudo chown gnome-remote-desktop:gnome-remote-desktop /etc/gnome-remote-desktop/rdp-tls.{crt,key}
sudo chmod 640 /etc/gnome-remote-desktop/rdp-tls.{crt,key}

sudo grdctl --system rdp set-tls-cert /etc/gnome-remote-desktop/rdp-tls.crt
sudo grdctl --system rdp set-tls-key  /etc/gnome-remote-desktop/rdp-tls.key
```

Start it and confirm what it thinks its own state is:

```bash
sudo systemctl enable --now gnome-remote-desktop.service
sudo grdctl --system status
```

`status` should show RDP enabled, the username, and the certificate paths. Open
the port and find the address:

```bash
sudo ufw allow 3389/tcp && sudo ufw reload
ip -4 addr show | grep inet
```

Connect with `mstsc` (Windows), Microsoft Remote Desktop (macOS) or `remmina`
(Linux). The client will warn about the self-signed certificate on first
connect; that is expected.

Other `grdctl` verbs worth knowing (`man grdctl` for the rest):

```bash
sudo grdctl --system rdp disable
sudo grdctl --system rdp clear-credentials
sudo grdctl --system rdp enable-view-only     # look, do not touch
sudo grdctl --system rdp disable-view-only    # allow control (default)
```

**Troubleshooting.** Connection refused → check the service is running and the
port is listening (`ss -tlnp | grep 3389`). Login rejected → you are almost
certainly using the Linux password instead of the one set with
`set-credentials`. Otherwise check the service and read the log:

```bash
sudo systemctl status gnome-remote-desktop.service      # system mode
systemctl --user status gnome-remote-desktop.service    # user mode
sudo journalctl -u gnome-remote-desktop.service -e     # system mode
journalctl --user -u gnome-remote-desktop.service -e   # user mode
```

### Option B — `xrdp` with GNOME Flashback

Use this when GNOME Shell is not an option. **GNOME Shell requires hardware 3D
acceleration, which the xrdp virtual display cannot provide** — it crashes or
gives a black screen. Flashback uses Metacity, a 2D window manager, while
keeping GNOME's applications and settings.

| Desktop | Needs 3D | Works over xrdp | Weight |
|---|---|---|---|
| GNOME Shell | yes | no — crashes without a GPU | heavy |
| GNOME Flashback | no | yes | medium |
| XFCE | no | yes | light |

```bash
sudo apt update
sudo add-apt-repository universe
sudo apt install -y xrdp gnome-session-flashback dbus-x11
sudo systemctl enable xrdp xrdp-sesman
```

Set the session for all users, keeping a copy of the original:

```bash
sudo cp /etc/xrdp/startwm.sh /etc/xrdp/startwm.sh.bak
sudo tee /etc/xrdp/startwm.sh >/dev/null <<'STARTWM'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user import-environment DISPLAY XAUTHORITY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP 2>/dev/null
fi

# per-user override wins if present
if [ -f ~/.xsession ]; then
    . ~/.xsession
    exit 0
fi

exec gnome-session --session=gnome-flashback-metacity
STARTWM
sudo chmod 755 /etc/xrdp/startwm.sh
sudo systemctl restart xrdp xrdp-sesman
```

A single user wanting a different desktop creates `~/.xsession`, which the
script above defers to:

```bash
echo "xfce4-session" > ~/.xsession && chmod +x ~/.xsession
```

**Troubleshooting.**

| Symptom | Cause | Fix |
|---|---|---|
| Session exits immediately | wrong session name | `ls /usr/share/gnome-session/sessions/gnome-flashback*` and match it exactly |
| Black screen or auth popups | PolicyKit / 3D | confirm Flashback, not Shell, is being started |
| Cannot connect at all | service down or firewall | `systemctl status xrdp xrdp-sesman`, open 3389 |
| GNOME Shell starts instead | a stale `~/.xsession` | remove it |

Logs live in `/var/log/xrdp-sesman.log` and `~/.xsession-errors`.

**The colord authentication popup.** A recurring xrdp symptom is a
"Authentication is required to create a color managed device" prompt on every
login, which a remote session often cannot dismiss. Grant it once, for all
users:

```bash
sudo tee /etc/polkit-1/rules.d/02-allow-colord.rules >/dev/null <<'POLKIT'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.color-manager.create-device" ||
         action.id == "org.freedesktop.color-manager.create-profile" ||
         action.id == "org.freedesktop.color-manager.delete-device" ||
         action.id == "org.freedesktop.color-manager.delete-profile" ||
         action.id == "org.freedesktop.color-manager.modify-device" ||
         action.id == "org.freedesktop.color-manager.modify-profile") &&
        subject.isInGroup("users")) {
        return polkit.Result.YES;
    }
});
POLKIT
```

Remove that file as part of any rollback.

**When the session dies before you see anything**, make `~/.xsession` log what
it did — this is the only way to see why `startwm.sh` bailed:

```bash
cat > ~/.xsession <<'XSESSION'
#!/bin/sh
exec > /tmp/xrdp-session-debug.log 2>&1
set -x

export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=GNOME-Flashback:GNOME
export XDG_SESSION_DESKTOP=gnome-flashback-metacity
export GNOME_SHELL_SESSION_MODE=ubuntu

ls -la /usr/share/gnome-session/sessions/gnome-flashback*
exec gnome-session --session=gnome-flashback-metacity
XSESSION
chmod +x ~/.xsession
```

Reconnect, then read `/tmp/xrdp-session-debug.log`. Delete the file again once
the session works, or it keeps overriding `startwm.sh`.

Rolling back is the `.bak` copy taken above:

```bash
sudo cp /etc/xrdp/startwm.sh.bak /etc/xrdp/startwm.sh
sudo rm -f /etc/polkit-1/rules.d/02-allow-colord.rules
sudo systemctl restart xrdp xrdp-sesman
```

### Do not put 3389 on the internet

RDP is a standing brute-force target and neither option above is hardened for
public exposure. Reach it over a VPN (WireGuard, Tailscale), or tunnel it over
SSH and connect the client to `localhost`:

```bash
ssh -L 3389:localhost:3389 user@host
```

Then point the RDP client at `localhost:3389`.

## Git

Submodule recovery, `core.longpaths`, `git clean -fdx` and the conflict
resolution procedure are in
[Adopting in a new project § Submodule maintenance](adopting-in-a-new-project.md#submodule-maintenance).
General-purpose bits that do not belong there:

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

Delete local branches whose remote is gone:

```bash
git fetch --prune
git branch -vv | grep ': gone' | awk '{print $1}'                      # review first
git branch -vv | grep ': gone' | awk '{print $1}' | xargs -r git branch -d
```

Track an upstream you do not own:

```bash
git remote add upstream https://github.com/user/repo
git pull upstream main
git push origin main
```

What does this branch have that `main` does not:

```bash
git log main..my-branch
```

Tag a release:

```bash
git tag -a v1.0.0 -m "Release 1.0.0"
git push origin v1.0.0
```

Inspect history size before rewriting it:

```bash
uv pip install git-filter-repo
git filter-repo --analyze
```

After rewriting history on one machine, every other clone must reset rather than
merge:

```bash
git fetch origin
git checkout develop
git reset --hard origin/develop
```

## Odds and ends

Terminal opens without a shell (`chsh` was set to something invalid):

```bash
chsh -s /bin/bash
```
