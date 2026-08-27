# Rancher Desktop: the supported way to run Linux containers on Windows

**Rancher Desktop is the preferred Linux-container runtime on this host.** It
runs containers in a WSL2 distro, so the Linux CI image can be run locally and a
CI failure reproduced on the dev box instead of guessed at through 25-minute
pipeline round trips.

It does **not** replace the Windows-container lane. Windows containers still go
through Stevedore's `docker.exe` — see [`windows-builds.md`](windows-builds.md).
The two coexist: different runtimes, different images, different jobs.

## Install

```pwsh
winget install -e --id SUS.RancherDesktop
```

Verify it is up:

```pwsh
& "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\rdctl.exe" version
```

`rdctl client version: v1.23.1, targeting server version: v1` means the backend
is running. It provisions two WSL distros, `rancher-desktop` and
`rancher-desktop-data`, which are its own — leave them alone.

## Use `nerdctl`, not `docker`

Rancher Desktop defaults its container engine to **containerd**, and the CLI for
containerd is `nerdctl`. This is the single most common thing to get wrong here,
because `docker.exe` also ships in the same directory and *appears* to work
while talking to a completely different engine.

```pwsh
$nerdctl = "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
& $nerdctl --namespace default run --rm alpine:3.20 uname -a
# Linux ... 6.18.33.2-microsoft-standard-WSL2 ... x86_64 Linux
```

That `uname` output is the check that matters: it proves a *Linux* kernel is
serving the container. Running `docker.exe info` on this host instead reports
`OSType=windows`, because the default docker context points at the Windows
engine used by the Stevedore lane. Both CLIs are on the box; only one of them is
talking to Linux.

`--namespace default` is worth passing explicitly. containerd namespaces are
real isolation, and images pulled into one namespace are invisible from another
— an image can be present and still "not found".

If you would rather use the `docker` CLI, switch Rancher Desktop's container
engine from `containerd` to `dockerd (moby)` in its settings. Then `docker`
targets Rancher and `nerdctl` stops being the entry point. Pick one and stay
with it; mixing them is how you end up debugging a missing image that is sitting
in the other engine's store.

## The image: always `:latest-cross`

**Use `ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross` for Linux
builds, in CI and locally.** Not `:latest`.

`:latest-cross` is the only published 3-arch tag: `linux/amd64`, `linux/arm64`
and `linux/riscv64`, re-shipped with fresh per-arch digests on every validating
rebuild (see the CHANGELOG entries that name them).

`:latest` is not a staler alternative — it is a dead tag, and pulling it fails
outright. Its three per-platform children had 404'd for months while the index
itself still resolved, so a pull reports only "manifest unknown"; that is why
`.github/workflows/python-ci-linux.yml:118` spells out "Do NOT fall back to plain
`:latest`". The dangling index was then deleted in the 2026-08-27 registry
cleanup (81 -> 34 tags). It will not come back on its own: every orchestrator
under `linux/scripts/` is a `build-cross-*` script, so the native lane has no
build path that could republish it.

`.github/workflows/python-ci-linux.yml` runs its containerized steps — static
analysis, tests, docs, packaging — in `:latest-cross` on both the x64 and arm64
runners (`CONTAINER_IMAGE` at :103, fed by the matrix at :126/:130 and consumed
by the `run-in-linux-container` action; the permission-fix and upload steps run
on the host). **Keep local runs on the same tag**, or reproducing a CI failure
locally proves nothing.

`:latest-cross` is not pinned by digest, so it still floats. Pinning would make
CI properly reproducible and is worth doing; it is not done yet.

## Reproducing a CI step locally

The Linux workflow mounts the repository at `/workspace` and runs the scripts in
`scripts/linux/`. The same shape works locally:

```pwsh
$nerdctl = "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
$image   = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"

& $nerdctl --namespace default run --rm `
  -v "D:\GitHub\Kataglyphis-BeschleunigerBallett:/workspace" `
  -w /workspace `
  $image `
  bash ./scripts/linux/cmake-configure-build.sh --preset linux-debug-clang --build-dir build-linux
```

Notes that will save time:

- **The image is large.** The first pull moves several GB; budget for it rather
  than assuming the command has hung.
- **Bind-mounting from a Dev Drive does not work** for the Windows lane and the
  same caution applies here — see the tar-fallback note in
  [`windows-builds.md`](windows-builds.md). If a mount behaves strangely, test
  with a path on a normal NTFS volume before blaming the container.
- **Build outputs land in the mounted tree**, so a Linux build directory will
  appear next to the Windows ones. Keep them under distinct `--build-dir` names
  (`build-linux`, `build-asan-clang`) or the two toolchains will fight over one
  CMake cache.

## When to reach for this

- A CI step fails and the logs are not enough. This is the main case, and it is
  worth the disk: the alternative is pushing commits to watch a pipeline.
- Something is suspected to be toolchain-specific — the Linux lane runs
  ASan/UBSan fuzzing that the Windows box does not, so a class of bug is only
  ever observable there.
- Verifying a fix before pushing, rather than after.

## Persisting the cargo cache

The `:latest-cross` image runs as uid 1001 with `/usr/local/cargo` owned by
root, so cargo falls back to a container-local `CARGO_HOME` and every fresh
container rebuilds all Rust dependencies from scratch. Point it at a named
volume instead:

```bash
nerdctl volume create cargo-cache        # once

MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' rdctl shell nerdctl run --rm --user root \
  -v cargo-cache:/cargo-cache \
  -v /mnt/d/path/to/repo:/workspace -w /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross \
  bash -c 'bash scripts/linux/cmake-configure-build.sh \
     --preset linux-debug-clang --build-dir /tmp/build --cargo-cache-dir /cargo-cache'
```

Three details that are easy to get wrong:

- **`--build-dir` must be container-native** (`/tmp/...`), not a path on the
  bind-mounted host tree. CMake's FetchContent `file RENAME` and cargo's
  temp-file cleanup both fail on that filesystem — the build dies partway
  through with a permission error on a stale artifact.
- The build driver also redirects `CARGO_TARGET_DIR` onto the same volume, so
  compiled artifacts stay off the host mount for the same reason.
- `--user root` sidesteps volume ownership. To avoid it, chown the volume to
  the image's uid once:
  ```bash
  rdctl shell nerdctl run --rm --user root -v cargo-cache:/cargo-cache \
    alpine:3.20 chown -R 1001:1001 /cargo-cache
  ```

The `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'` prefix is required when
invoking nerdctl from Git Bash — without it the `-v` argument is rewritten
into a Windows path and the run fails with "expected an absolute path".

After the first build the registry and compiled dependencies are reused and
subsequent runs are dramatically faster.

## Long-running work: detached containers + tmux

A build or training run that outlives your terminal should not be tied to it.
Start the container detached, then use tmux *inside* it so the process survives
both disconnects.

```bash
nerdctl run -dit --gpus '"device=0"' -p 8501:8501 \
  -v "$PWD:/workspace" -w /workspace \
  --name work ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross
```

| Flag | Why |
|---|---|
| `-d` | Detached — runs in the background |
| `-i` | Keeps STDIN open, so a shell attached later is usable |
| `-t` | Allocates a pseudo-TTY |
| `--name` | Stable handle; without it you are copying container ids around |

Attach, start a tmux session, run the job, then leave:

```bash
nerdctl exec -it work bash
tmux                      # then start the long job, e.g. python train.py
# detach from tmux with Ctrl+B then D, or just `exit` the shell
```

The container and the tmux session keep running. Reconnect later with:

```bash
nerdctl exec -it work bash
tmux attach
```

Useful handles:

```bash
nerdctl ps                # what is running
nerdctl stop work
nerdctl start work
nerdctl rm work
tmux ls                   # inside the container: list sessions
```

Name the session when you run more than one at a time — `tmux` alone gives
you an unnamed session that is awkward to pick out later:

```bash
tmux new -s build          # create
# Ctrl+B then D to detach
tmux attach -t build       # come back to that specific one
```

Two alternatives to tmux, for reference: `Ctrl+P` then `Ctrl+Q` detaches from an
attached container without stopping it (this is a container-level detach, not a
process-level one), and `nohup cmd > cmd.log 2>&1 &` backgrounds a single
process without a session manager. tmux is preferable when you want to look at
the running output again.

> `nerdctl` is largely command-compatible with `docker`. In most cases
> substituting one for the other is enough — but see the namespace caveat above.

## Fixing file ownership after a container writes to a bind mount

A container running as a different uid than your host user leaves files you
cannot edit. Rather than chowning from the host, do it from inside the container
where you have root.

Find the host uid/gid you want the files to end up as:

```bash
id -u && id -g
# ...or read it out of /etc/passwd:
grep "^$USER:" /etc/passwd
# youruser:x:1000:1000::/home/youruser:/bin/bash
#            ^^^^ ^^^^  uid  gid
```

Then, inside the container:

```bash
chown -R 1000:1000 /workspace/some/path
```

The same trick applies to named volumes — see
[Persisting the cargo cache](#persisting-the-cargo-cache), which chowns
`cargo-cache` to the image's uid 1001 once instead of running everything as
root.

## Setting up WSL2 itself

Rancher Desktop supplies its own distro, but a second WSL distro is often
wanted — for a Linux-side toolchain, or to reproduce a CI step outside the
container.

### Installing without the Microsoft Store

Store-less installs are the norm on managed or offline machines:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Reboot, then import a rootfs tarball from
[Ubuntu Cloud Images](https://cloud-images.ubuntu.com/wsl/):

```powershell
mkdir C:\WSL\Ubuntu24.04
wsl --import Ubuntu24.04 C:\WSL\Ubuntu24.04 .\ubuntu-24.04-wsl-rootfs.tar.gz
wsl -d Ubuntu24.04
```

An imported distro starts as root with no user account:

```bash
passwd
adduser <youruser>
usermod -aG sudo <youruser>
```

```powershell
wsl -d Ubuntu24.04 -u <youruser>
wsl --set-default Ubuntu24.04
```

### Stop Windows executables shadowing Linux ones

By default WSL appends the whole Windows `PATH`, so `python`, `node` or `cmake`
can resolve to a Windows binary inside a Linux shell — with confusing results in
a build script. In `/etc/wsl.conf`:

```ini
[interop]
enabled=true
appendWindowsPath=false
```

Windows executables remain callable by full path; they just stop winning `PATH`
lookups. Restart the distro (`wsl --shutdown`) for it to take effect.

### The virtual disk only grows

WSL2's ext4 disk never shrinks on its own. Reclaim it the same way as the
[Docker VHD](windows-builds.md):

```powershell
wsl --shutdown
cd C:\WSL\Ubuntu24.04
Optimize-VHD -Path .\ext4.vhdx -Mode Full
```

### No network inside WSL once a VPN connects

A known WSL networking interaction rather than a VPN misconfiguration. Install
the latest WSL from [its releases](https://github.com/microsoft/WSL/releases)
rather than relying on the inbox version:

```powershell
Add-AppxPackage .\Microsoft.WSL_<version>_x64_ARM64.msixbundle
```

Then set the networking mode in WSL Settings. Microsoft's
[troubleshooting note](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#wsl-has-no-network-connectivity-once-connected-to-a-vpn)
covers the remaining cases.

### USB passthrough (cameras, probes, boards)

Needed whenever a device has to be visible to a Linux toolchain — see
[Microsoft's guide](https://learn.microsoft.com/en-us/windows/wsl/connect-usb):

```powershell
usbipd list
usbipd attach --wsl --busid 1-1.2
```

Attaching is not the whole story: the device appears on the USB bus but the
kernel module still has to claim it. For a UVC camera that shows up with no
`/dev/video*`:

```bash
sudo modprobe uvcvideo videodev
lsmod | grep -E 'uvcvideo|videodev'
ls -l /dev/video*
v4l2-ctl --list-devices
dmesg | tail -n 40
```

If the device is listed but still unbound, bind its interfaces by hand — replace
the vendor id with your own from `lsusb`:

```bash
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor")" = "174f" ] || continue
  for iface in "$d"/*:*; do
    [ -e "$iface" ] || continue
    echo -n "$(basename "$iface")" | sudo tee /sys/bus/usb/drivers/uvcvideo/bind
  done
done
```
