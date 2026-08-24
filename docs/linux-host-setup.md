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
