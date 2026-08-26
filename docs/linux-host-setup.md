# Linux Host Setup (GPU, drivers, runtime, boot)

Goal: take a **fresh Ubuntu/Debian host** to a state where it can build and run
this repo's Linux images with GPU acceleration. This is the Linux counterpart to
[Fresh Windows Host Bring-Up](windows-host-setup.md).

Scope is the **host**, not the images. What goes inside a container is owned by
[Linux Build Basics](linux-build-basics.md) and
[Linux Accelerator Images](linux-accelerator-images.md); running Linux
containers from a Windows host is
[Rancher Desktop](rancher-desktop-linux-containers.md).

Every phase ends with a verify command. Run them — a driver that installed
without error but did not load is the common failure here, and it looks
identical to success until the first build.

---

## Phase A — GPU drivers

### A1. NVIDIA driver

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y build-essential linux-headers-$(uname -r)

sudo ubuntu-drivers devices        # list what this GPU supports
sudo ubuntu-drivers install        # let the tool pick
# ...or pin a specific branch:
# sudo apt install -y nvidia-driver-590
```

Reboot afterwards. The kernel module is only loaded on a fresh boot.

Verify:

```bash
nvidia-smi
```

### A2. CUDA toolkit

`ubuntu-drivers` does not install the toolkit — `nvcc` comes separately.

```bash
sudo add-apt-repository -y multiverse
sudo apt update
sudo apt install -y cuda-toolkit
```

CUDA does not put itself on `PATH`. Add a profile drop-in so every login shell
and every build script sees it:

```bash
sudo tee /etc/profile.d/cuda-path.sh >/dev/null <<'PROFILE'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
PROFILE
```

Verify (in a **new** shell):

```bash
nvcc --version
```

### A3. Purge and recover a broken NVIDIA install

A half-upgraded driver stack is the usual cause of `nvidia-smi` failing after an
`apt upgrade`. Do not fight it incrementally — purge and reinstall.

First see what was pulled in manually, so you know what to put back:

```bash
sudo apt-mark showmanual | grep -E 'nvidia|cuda'
```

Then remove everything, including the repo definitions:

```bash
sudo apt-get remove --purge '^nvidia-.*' 'libnvidia-*' 'linux-modules-nvidia-*' -y
sudo apt purge -y 'cuda-*' 'nsight-*'
sudo apt autoremove --purge -y
sudo apt autoclean

sudo rm -f /etc/apt/sources.list.d/cuda*.list
sudo rm -f /etc/apt/sources.list.d/nvidia*.list
sudo rm -f /usr/share/keyrings/cuda-archive-keyring.gpg
sudo dpkg -P cuda-keyring 2>/dev/null || true

sudo dpkg --configure -a
sudo apt --fix-broken install -y
sudo apt update
sudo reboot
```

Then start again at [A1](#a1-nvidia-driver).

### A4. AMD

AMD GPUs need no proprietary driver package for the ROCm lane — the kernel
driver is in-tree. What is sometimes missing is firmware:

```bash
sudo apt install -y linux-firmware
```

Verify:

```bash
rocm-smi
```

---

## Phase B — Container runtime host config

### B1. Docker without sudo

```bash
sudo usermod -aG docker $USER
```

Log out and back in — group membership is only picked up on a new session.

### B2. Make the NVIDIA runtime the default

Without this, every GPU container needs an explicit `--runtime nvidia`, and
Compose files that omit it silently run on CPU.

```bash
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json >/dev/null <<'DAEMON'
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
DAEMON

sudo systemctl daemon-reload
sudo systemctl restart docker
```

Verify:

```bash
docker info | grep -i 'default runtime'
```

### B3. Cap container log growth

A long build or a chatty service will fill the disk with JSON logs. Merge these
keys into the same `daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Restart Docker afterwards. Disk exhaustion mid-build surfaces as
`no space left on device` deep inside a compile step — see
[Build resource monitoring](build-resource-monitoring.md).

### B3b. Install or upgrade `nerdctl-full`

`nerdctl-full` ships nerdctl together with the whole stack it drives —
containerd, BuildKit (`buildkitd` + `buildctl`), runc, the CNI plugins, the
snapshotters and the rootless helpers. They are version-matched, so on this
host **upgrading buildkitd means upgrading the bundle**; there is no separate
buildkit package to bump.

```bash
bash linux/host-config/install-nerdctl-full.sh                    # dry run: version delta + plan
NERDCTL_INSTALL_CONFIRM=1 bash linux/host-config/install-nerdctl-full.sh
bash linux/host-config/install-nerdctl-full.sh --rollback         # restore the backup
```

Knobs: `NERDCTL_VERSION=x.y.z` pins a release (default: latest),
`NERDCTL_PREFIX` (default `/usr/local`), `NERDCTL_BACKUP_DIR`, `NERDCTL_FORCE=1`
(re-install the version already present), `NERDCTL_SKIP_CACHE_CENSUS=1` (proceed
without a cache baseline when buildkitd is down).

**This host runs rootless AND rootful side by side, and that changes the
procedure.** The `systemd --user` units are the rootless stack the chain builds
with; but a rootful `containerd.service` *and* `buildkit.service` also run, and
they execute the same `/usr/local/bin` binaries plus unit files the bundle
ships in `/usr/local/lib/systemd/system`. Extracting the bundle replaces all of
that underneath them. Measured on this host: GNU tar 1.35 and `cp -a` both
unlink-and-recreate rather than failing with `ETXTBSY`, so there is **no error
at all** — the root daemons simply keep executing the now-deleted old inode,
and because both units are `Restart=always` the real version jump then happens
unattended at some later moment. The script therefore refuses unless you choose:

```bash
NERDCTL_INCLUDE_ROOTFUL=1 ...   # stop, upgrade and restart them too — no skew
NERDCTL_IGNORE_ROOTFUL=1  ...   # rootless only; accept the documented skew
```

A dry run always shows the plan and the choice — only the actual install is
blocked.

What the script guarantees, and why each guard exists:

- **It refuses while a build runs.** Extracting over live binaries mid-chain
  kills the run; chains here regularly last 10+ hours.
- **It verifies the release SHA256** against the published `SHA256SUMS` before
  touching anything, and refuses if the checksum is missing.
- **It backs up exactly the `bin/` binaries the bundle ships**, so
  `--rollback` puts nerdctl, buildkitd/buildctl, containerd and runc back.
  Know its scope: the bundle also ships `libexec/` (CNI), systemd units and
  `share/`, and those stay at the newly installed version. That is harmless
  for the build path, but a rollback is *not* a full downgrade — for that,
  re-run with `NERDCTL_VERSION=<previous>`.
- **It counts BuildKit cache-mount records before and after.** Compile caches
  (ccache/sccache/uv/cargo/cerbero) live in `~/.local/share/buildkit`, not in
  `/usr/local`, so an upgrade must not change that number — see
  [`prune-safe.sh`](../linux/host-config/prune-safe.sh) for why those records
  are the thing worth protecting.
- **It proves the stack came back up** (`nerdctl images`, `buildctl du`,
  service active) instead of assuming, and tells you the rollback command if
  it did not.

**When it is worth upgrading** (checked 2026-08-26): this host runs buildctl
`v0.31.1`. BuildKit `v0.31.0` introduced a daemon crash — *"concurrent map
iteration and map write"* ([moby/buildkit#6915][bk6915]) — that reproduces
under **concurrent** builds, which is exactly how this chain drives it with
three arch lanes at once. The fix ships in BuildKit `v0.31.2`, bundled by
nerdctl-full `2.3.5`. Two caveats, so nobody upgrades expecting the wrong
thing: it will **not** cure [BKD1](failure-modes.md) — the buildkitd session
rot (export hangs, `no active session`, lost layer blobs) has no upstream fix
and is still cured by stopping the chain and restarting the service — and the
parallel-build cache-miss fix ([moby/buildkit#6954][bk6954]) landed in
`v0.32.0`, which no nerdctl-full release ships yet.

[bk6915]: https://github.com/moby/buildkit/issues/6915
[bk6954]: https://github.com/moby/buildkit/issues/6954

Afterwards run `linux/host-config/verify-host-config.sh` and
`linux/scripts/preflight.sh` before starting the next chain — the daemon
restart is also the moment the staged `buildkitd.toml` gcpolicy takes effect.

### B4. Verify a `nerdctl-full` install

The `nerdctl-full` tarball bundles containerd, BuildKit, runc, snapshotters and
the rootless helpers. A partial extraction leaves some of them off `PATH`, and
the symptom is a confusing failure much later — a build that cannot find
`buildctl`, or rootless mode silently unavailable. Check all of them at once:

```bash
#!/usr/bin/env bash
binaries=(
    nerdctl containerd runc buildkitd buildctl
    containerd-stargz-grpc ctd-decoder
    slirp4netns bypass4netns
    fuse-overlayfs containerd-fuse-overlayfs-grpc
    tini buildg rootlesskit gomodjail
)

for cmd in "${binaries[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '\nOK   %s: ' "$cmd"
        "$cmd" --version 2>/dev/null || "$cmd" version 2>/dev/null \
            || echo "(no standard version flag)"
    else
        printf '\nMISS %s (not on PATH)\n' "$cmd"
    fi
done
```

### B5. TLS handshake failures inside containers

A container that cannot resolve names — `TLS handshake timeout` on an image
pull, or `apt` failing to reach a mirror — is usually the host handing it an
unreachable resolver.

```bash
# temporary: overwrite the resolver and restart the runtime
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" | sudo tee /etc/resolv.conf
sudo systemctl restart containerd
```

On a systemd-resolved host, `/etc/resolv.conf` is a managed symlink and the edit
above will be reverted. Make it stick in `/etc/systemd/resolved.conf` instead:

```ini
[Resolve]
DNS=8.8.8.8 8.8.4.4
FallbackDNS=1.1.1.1
```

```bash
sudo systemctl restart systemd-resolved
```

### B6. UFW silently breaks container networking

If the firewall is enabled, containers can lose outbound networking entirely —
image pulls hang, `apt` inside a build reaches nothing. UFW defaults to dropping
forwarded traffic, which is exactly what a container bridge relies on.

```bash
sudo nano /etc/default/ufw
# DEFAULT_FORWARD_POLICY="ACCEPT"
sudo ufw reload
```

This is the Linux counterpart to the Windows lane's CNI `.conf` requirement —
in both cases the build looks correctly configured and the RUN steps simply have
no network. Check this before debugging a mirror or a DNS resolver.

---

## Phase C — Performance mode

Build hosts ship in a power-saving governor by default, which costs real
wall-clock on long compiles.

### C1. CPU frequency governor

Check what is active:

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

Expect one of `powersave`, `schedutil`, or `performance`.

Set it for the current boot — either form works:

```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
# ...or, if cpupower is installed:
sudo cpupower frequency-set -g performance
```

Make it survive a reboot:

```bash
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'UNIT'
[Unit]
Description=Set CPU to performance mode
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now cpu-performance.service
```

### C2. AMD GPU performance level

```bash
sudo rocm-smi --setperflevel high            # all devices
sudo rocm-smi --setperflevel high --device 0 # one device
```

Inspect:

```bash
rocm-smi --showclkfrq      # current clock frequencies
rocm-smi --showperflevel   # current performance level
rocm-smi --showprofile     # available performance profiles
```


### C3. Stop the host suspending mid-build

A machine that suspends during a multi-hour cross chain kills the run. Desktop
installs enable idle suspend by default, so this is a required step on any host
that builds unattended — not an optimization.

In `/etc/systemd/logind.conf`:

```ini
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
```

```bash
sudo systemctl restart systemd-logind
```

`logind` only covers keys and the lid. Block the sleep targets themselves as
well, or something else can still trigger a suspend:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

And belt-and-braces in `/etc/systemd/sleep.conf`:

```ini
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
```

Verify:

```bash
systemctl status sleep.target      # should read: masked
```

On laptop-class hardware also check that TLP is not overriding the governor set
in [C1](#c1-cpu-frequency-governor): `systemctl status tlp`.
---

## Phase D — Host toolchain

### D1. A newer GCC than the distro ships

```bash
# only if add-apt-repository is missing:
sudo apt install --reinstall -y software-properties-common \
  python3-software-properties python3-launchpadlib

sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt update
sudo apt install -y gcc-11 g++-11
```

Register the alternatives and pick one:

```bash
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 60
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 60
sudo update-alternatives --config gcc
sudo update-alternatives --config g++
```

Verify:

```bash
gcc --version && g++ --version
```

> The **image** toolchain is pinned separately in
> `linux/scripts/01-core/versions.env` and built by `linux/Dockerfile.toolchain`.
> This section is only about the host compiler — for building a kernel module or
> a driver out-of-tree.

### D2. Flutter on ARM hosts

After installing the SDK on an ARM host, **delete the `cache` folder inside the
SDK directory**. It ships x86_64 artifacts that are not replaced automatically,
and the failure surfaces much later as an unrelated-looking tool crash.

### D3. Multiple clang versions side by side

Same mechanism as GCC above, for the compiler the build lanes actually use:

```bash
sudo update-alternatives --install /usr/bin/clang   clang   /usr/bin/clang-20   100
sudo update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-20 100
sudo update-alternatives --config clang
sudo update-alternatives --config clang++
```

Set both, not just `clang` — a mismatched `clang`/`clang++` pair produces link
errors that read like a missing standard library.

---

## Phase E — Package sources and automatic updates

### E1. A slow `apt update` is usually the mirror, not the link

Measured on this host: `apt update` took **107 s** on a 254 Mbit/s connection.
The cause was `security.ubuntu.com` round-robin DNS resolving to an unhealthy
node — nothing to do with local bandwidth. Swapping to the regional mirror took
it to **under 3 s**.

This matters beyond the host: every image build starts with `apt update`, so a
bad mirror is paid on every uncached layer.

Confirm it is the mirror and not the link or IPv6:

```bash
speedtest-cli                                  # is the link actually slow?
time sudo apt -o Acquire::ForceIPv4=true update # is it IPv6?

# where exactly does it stall?
time sudo apt update 2>&1 | while IFS= read -r line; do
  echo "$(date +%H:%M:%S) $line"
done
```

Then swap the mirror:

```bash
sudo cp /etc/apt/sources.list.d/ubuntu.sources ~/ubuntu.sources.bak
sudo sed -i 's|http://security.ubuntu.com/ubuntu|http://de.archive.ubuntu.com/ubuntu|g' \
  /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```

> Keep the backup **outside** `/etc/apt/sources.list.d/`. A `.bak` file left in
> that directory is parsed as a second source and apt warns on every run.

Revert with `sudo cp ~/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources`.

### E2. Unattended upgrades

```bash
sudo apt install -y unattended-upgrades apt-listchanges
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

Non-interactively, `/etc/apt/apt.conf.d/20auto-upgrades`:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
```

Which origins are allowed is set in `/etc/apt/apt.conf.d/50unattended-upgrades`.
Security-only is the conservative default:

```text
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        // "${distro_id}:${distro_codename}-updates";
};
```

**Excluding a package is the important part on a build host.** An unattended
Docker upgrade is how a working container runtime breaks overnight — see the
Jetson case in
[Linux Accelerator Images § Edge accelerators](linux-accelerator-images.md#edge-accelerators):

```text
Unattended-Upgrade::Package-Blacklist {
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
};
```

Other options worth setting deliberately rather than by default:

```text
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "02:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailOnlyOnError "true";
```

`Unattended-Upgrade::Mail` needs a working MTA on the host, or the notification
is silently dropped. `msmtp` is the least-effort option — it relays to an
existing mailbox rather than running a mail server:

```bash
sudo apt install -y mailutils msmtp msmtp-mta
```

Configure it per-user in `~/.msmtprc` — **create this without sudo**, and give
it mode 600 or msmtp refuses to use it:

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        ~/.msmtp.log

account        mymail
host           smtp.example.com
port           587
from           builder@example.com
user           builder@example.com
password       <APP_PASSWORD>

account default : mymail
```

```bash
chmod 600 ~/.msmtprc
echo "test" | mail -s "Test from $(hostname)" you@example.com
```

For a provider with 2FA, this needs an **app password**, not the account
password. The file holds that credential in plaintext, so it belongs in the
build user's home on the host, never in a repo.

Automatic reboots interrupt long builds — leave it off on a machine that runs
the chain unattended.

If the host uses kernel livepatching (Canonical Livepatch) or a vendor kernel,
read that vendor's guidance first — unattended-upgrades may still install kernel
packages without rebooting into them, so `uname -r` and the installed package
drift apart silently.

Dry-run and check it is actually firing:

```bash
sudo unattended-upgrades --dry-run --debug
systemctl list-timers --all | grep apt      # apt-daily / apt-daily-upgrade
sudo journalctl -u unattended-upgrades --no-pager
```

Logs also land in `/var/log/unattended-upgrades/unattended-upgrades.log`.

### E3. Turning automatic updates off entirely

On a build host that must not change underneath a running chain:

```bash
sudo systemctl stop    unattended-upgrades.service
sudo systemctl disable unattended-upgrades.service
sudo systemctl mask    unattended-upgrades.service

sudo systemctl stop    apt-daily.timer apt-daily-upgrade.timer
sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer
sudo systemctl mask    apt-daily.timer apt-daily-upgrade.timer
```

Masking, not just disabling — a dependency can re-enable a merely disabled unit.


### E4. Pinning a package to a specific source or version

`Package-Blacklist` in [E2](#e2-unattended-upgrades) stops a package being
upgraded. Pinning is the other half: it forces which source a package comes
from, which is what you want when the distro's version is wrong for the host
(an older driver branch, a vendor repo, a PPA).

```bash
sudo tee /etc/apt/preferences.d/my-pin >/dev/null <<'PIN'
Package: somepackage*
Pin: release o=LP-PPA-somevendor
Pin-Priority: 1001
PIN
```

A priority above 1000 permits a *downgrade* to that source, which is the point —
anything at or below 1000 will not pull a package backwards. To exclude a source
entirely, pin it negative:

```bash
sudo tee /etc/apt/preferences.d/no-distro-version >/dev/null <<'PIN'
Package: somepackage*
Pin: release o=Ubuntu
Pin-Priority: -1
PIN
```

Always verify which candidate actually won — pinning fails quietly:

```bash
sudo apt update
apt-cache policy somepackage
```

> **The trap:** APT preferences require **each field on its own line**. A
> single-line `echo "Package: x Pin: ... Pin-Priority: ..."` writes a file APT
> parses as garbage and ignores, with no error. The symptom is a pin that simply
> does nothing, which reads as "pinning doesn't work here".

If the pinned package comes from a PPA and you want unattended-upgrades to keep
it current, that origin has to be allowed explicitly:

```bash
echo 'Unattended-Upgrade::Allowed-Origins:: "LP-PPA-somevendor:${distro_codename}";' \
  | sudo tee /etc/apt/apt.conf.d/51unattended-upgrades-somevendor
```
---

## Troubleshooting

### Reading the journal

```bash
# errors in a date window
journalctl -p err --since "2025-04-21" --until "2025-04-22"

# search the last week of messages by text
journalctl --since "1 week ago" --grep "Error message"

# kernel ring buffer from the PREVIOUS boot — for anything that hard-locked
journalctl -k -b -1 | grep -i thermal
```

The `-b -1` form is the one that matters after a machine wedges: the current
boot's log will not contain the cause.

### `nvidia-smi` reports a device it cannot address

```
Unable to determine the device handle for GPU1: 0000:28:00.0: Unknown Error
```

Seen on a dual-GPU host: the PSU could not supply both cards. It is a **power**
fault, not a driver fault — reinstalling the driver will not help. Run one GPU,
or move to a PSU that covers both.

### Boot drops to a GRUB prompt

A `grub>` shell means GRUB loaded its modules but could not find `grub.cfg`;
`grub rescue>` means it could not even load `normal.mod`. Usual causes are
partition renumbering or UUID changes after a resize or clone, an overwritten
bootloader after installing another OS, or deleted `/boot/grub/*`.

**Boot once from the prompt:**

```
grub> ls                                  # find the partition holding /boot/grub
grub> set root=(hd0,msdos1)
grub> set prefix=(hd0,msdos1)/boot/grub
grub> insmod normal
grub> normal
```

**Then fix it permanently.** Identify the *disk*, not the partition:

```bash
lsblk -d -o NAME,SIZE,MODEL
sudo grub-install /dev/sda        # or /dev/nvme0n1
sudo update-grub
```

Check that `/etc/default/grub` has `GRUB_TIMEOUT` greater than zero, and verify
the UEFI boot order lists the Linux entry before Windows:

```bash
sudo efibootmgr -v
```

Fast Boot can skip keypress detection and Secure Boot can block unsigned
modules — disable both while diagnosing.

If the manual steps do not get you booting, Boot-Repair automates most of them
and is worth trying before a reinstall:

```bash
sudo add-apt-repository -y ppa:yannubuntu/boot-repair
sudo apt update
sudo apt install -y boot-repair
boot-repair          # choose "Recommended repair"
```

### Choosing the default boot entry

```bash
# what entries exist
grep -E "^menuentry|^submenu" /boot/grub/grub.cfg
```

Set a permanent default in `/etc/default/grub` (`GRUB_DEFAULT=0`, or a name such
as `GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-45-generic"`),
then run `sudo update-grub`.

Remember the last selection instead:

```bash
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
sudo sed -i 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub
sudo update-grub
```

Boot into one entry exactly once:

```bash
sudo grub-reboot "Windows Boot Manager (on /dev/sda2)"
sudo reboot
```

Or set the next boot via UEFI, which does not need a working GRUB config:

```bash
sudo efibootmgr -v
sudo efibootmgr -n 0003
sudo reboot
```

From a rescue system with the root filesystem mounted, `grubenv` can be written
directly:

```bash
sudo grub-editenv /mnt/nvme0root/boot/grub/grubenv set next_entry=9
sudo grub-editenv /mnt/nvme0root/boot/grub/grubenv list
```

### Finding what filled the disk

`no space left on device` from a build step is a host problem, not a build
problem. Locate the consumer before pruning anything:

```bash
du -sh .                                        # this directory
sudo du -ah --max-depth 2 . | sort -h           # what is under it
sudo du -ah / --max-depth=2 | sort -hr | head -20   # worst offenders, whole disk
```

On a WSL host, exclude the Windows mounts or the scan walks the entire C: drive
and reports it as Linux usage:

```bash
sudo du -ah / --max-depth=2 --exclude='/mnt/*' | sort -hr | head -20
```

`ncdu` is the interactive form and usually faster to act on:

```bash
sudo apt install -y ncdu
ncdu /
```

Container images and the build cache are the usual answer. Reclaim those through
`linux/host-config/prune-safe.sh`, which is written to spare the compile-cache
mounts — a plain `docker system prune` throws away the ccache/sccache tiers and
the next build pays for it.

### `/tmp` is full during a build

`/tmp` is often a tmpfs sized to a fraction of RAM, and a large build can
exhaust it. Resize it for the current boot:

```bash
free -h                                  # check there is RAM to give
sudo mount -o remount,size=8G /tmp
```

To clear it without removing the directory or losing its permissions:

```bash
sudo find /tmp -mindepth 1 -maxdepth 1 -exec rm -rf {} +
sudo chmod 1777 /tmp                     # sticky bit must be restored
```

Never `rm -rf /tmp` itself — recreating it without mode `1777` breaks every
service that writes there.
