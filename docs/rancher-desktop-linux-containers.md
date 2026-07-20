# Rancher Desktop: the supported way to run Linux containers on Windows

**Rancher Desktop is the preferred Linux-container runtime on this host.** It
runs containers in a WSL2 distro, so the Linux CI image can be run locally and a
CI failure reproduced on the dev box instead of guessed at through 25-minute
pipeline round trips.

It does **not** replace the Windows-container lane. Windows containers still go
through Stevedore's `docker.exe` — see [`windows-builds.md`](windows-builds.md).
The two coexist: different runtimes, different images, different jobs.

## Install

```powershell
winget install -e --id SUS.RancherDesktop
```

Verify it is up:

```powershell
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

```powershell
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

Both tags publish `linux/amd64`, `linux/arm64` and `linux/riscv64`. The
difference is that they are maintained on different schedules:

| Tag | amd64 image built | Layers |
|---|---|---|
| `:latest-cross` | 2026-07-20 | 49 |
| `:latest` | 2026-04-16 | 60 |

`:latest` had gone three months without a rebuild while the cross lane was
rebuilt routinely. Building against a toolchain nobody refreshes is how a lane
drifts away from every other environment, and it makes "works on my machine"
unfalsifiable. `.github/workflows/Linux.yml` sets `CONTAINER_IMAGE` to
`:latest-cross` for exactly this reason — **keep local runs on the same tag**,
or reproducing a CI failure locally proves nothing.

Neither tag is pinned by digest, so both still float. Pinning would make CI
properly reproducible and is worth doing; it is not done yet.

## Reproducing a CI step locally

The Linux workflow mounts the repository at `/workspace` and runs the scripts in
`Scripts/Linux/`. The same shape works locally:

```powershell
$nerdctl = "C:\Program Files\Rancher Desktop\resources\resources\win32\bin\nerdctl.exe"
$image   = "ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross"

& $nerdctl --namespace default run --rm `
  -v "D:\GitHub\Kataglyphis-BeschleunigerBallett:/workspace" `
  -w /workspace `
  $image `
  bash ./Scripts/Linux/cmake-configure-build.sh --preset linux-debug-clang --build-dir build-linux
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
