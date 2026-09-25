<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Stevedore and docker on Windows — setup fixes and service recovery

Post-install fixes for a Stevedore host, plus the registry-auth, networking and
service-recovery problems that are properties of *docker on Windows* rather
than of this repo's chain.

For an ordered bring-up of a brand-new host start at
[`windows-host-setup.md`](windows-host-setup.md) — this page is the reference it
points into.
## Stevedore Setup Fixes

After installing Stevedore, apply these post-install fixes. They are the canonical source. Fixes 1 and 2 are for their symptom only (which symptom: [`windows-host-setup.md`](windows-host-setup.md) § A4); Fix 3 is for every host.

### Fix 1: Remove stale Docker Desktop daemon.json

If Docker Desktop was previously installed, its daemon config at `C:\ProgramData\docker\config\daemon.json` may specify a hosts pipe (`docker_engine_windows`) that conflicts with Stevedore's `docker_engine` pipe. Remove it:

```pwsh
if (Test-Path "C:\ProgramData\docker\config\daemon.json") { Remove-Item "C:\ProgramData\docker\config\daemon.json" }
```

### Fix 2: Change default runtime from hcsshim to runhcs

Stevedore's service defaults to the `com.docker.hcsshim.v1` runtime, but only the `io.containerd.runhcs.v1` shim binary (`containerd-shim-runhcs-v1.exe`) ships with Stevedore. Apply this only when `docker build` fails with `runtime "com.docker.hcsshim.v1" binary not installed`: the reference host runs without the flag. Update the service binary path:

```pwsh
sc config stevedore binPath="\"C:\Program Files\Stevedore\dockerd.exe\" --run-service --service-name stevedore --group docker-users --host npipe:////./pipe/dockerDesktopWindowsEngine --host npipe:////./pipe/docker_engine --containerd=npipe:////./pipe/containerd-containerd --default-runtime=io.containerd.runhcs.v1"
```

Then restart:

```pwsh
net stop stevedore /y
net start stevedore
```

### Fix 3: Windows Defender exclusions for containerd data

Add exclusions for the container stores (prevents hcsshim layer commit errors — `hcsshim::ActivateLayer failed (0x20)`, and the hcs-temp sharing-violation flakes):

```pwsh
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\buildkitd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
```

That is the core. The full set, with the process exclusions, is
[`windows-host-setup.md`](windows-host-setup.md) § C4, and
`windows\scripts\host\Sync-DefenderExclusions.ps1` applies it. A persistent
`ActivateLayer 0x20` on an AMD Radeon host is not Defender: it is the RDNA4
layer lock in the FIRST CHECK box at the top of that page.

### Fix 4: docker.exe vs nerdctl (historical — pre-CNI-conf state)

Before the CNI `nat` conf was installed (2026-08-03), `nerdctl build` lacked
DNS resolution and `nerdctl run` failed outright on this host (`failed to
create default network: needs CNI plugin "nat" to be installed in CNI_PATH` —
the conf, not the binary, was missing), so `docker.exe` was the only working
tool. Current state: with the CNI nat config installed in both forms
(`0-containerd-nat.conflist`, which nerdctl reads, and the `.conf` buildkitd
reads — [`windows-host-setup.md`](windows-host-setup.md) § A5) `nerdctl` works
from **admin** shells; builds go through
`Build-Buildkit.ps1`/buildctl on the preferred lane — Stevedore ships that
`buildctl.exe` too. Stevedore's `docker.exe` needs no CNI plugin and survives as
the **publish/inspect** tool, but it is not a build lane: fifteen of the
seventeen `windows/Dockerfile.*` (2026-09-25) use BuildKit-only `RUN --mount`,
so a `docker.exe build` of `Dockerfile.base` dies at its first `RUN` with
*"the --mount option requires BuildKit"* (the classic driver itself was deleted on 2026-08-31 —
[`windows-host-setup.md`](windows-host-setup.md) § R3. There is no classic lane to
reach for).

```pwsh
& "$env:ProgramFiles\Stevedore\bin\docker.exe" load -i out\bk-winamd64.tar            # a -FinalTar export
& "$env:ProgramFiles\Stevedore\bin\docker.exe" image inspect local/kataglyphis:winamd64
```

## Docker on Windows: registry auth, networking, service recovery

Traps that are specific to running the Docker CLI/daemon on a Windows host, as
opposed to the BuildKit/containerd lane above.

### `--password-stdin` does not work — ghcr.io login

The documented login form silently fails on Windows:

```powershell
# does NOT work here
echo $CR_PAT | docker login ghcr.io -u USERNAME --password-stdin
```

Two ways through. First, the credential helper is often the real culprit — open
`$env:USERPROFILE\.docker\config.json` and clear `credsStore` (typically
`wincred` or `desktop`), then retry an interactive `docker login`. See also
[`error getting credentials - err: exit status 1`](failure-modes.md#error-getting-credentials---err-exit-status-1)
in `failure-modes.md`, which is the same helper failing for dockerd-as-SYSTEM.

If that is not an option, write the auth entry directly:

```powershell
$username = "<user>"
$token    = "<GITHUB_PAT>"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${username}:${token}"))
```

```json
{
  "auths": {
    "ghcr.io": {
      "auth": "<the base64 string>"
    }
  }
}
```

The value is base64, **not** encryption — treat that file as a credential. Prefer
a short-lived PAT, and see [Build secrets](build-secrets.md) for getting a token
into a *build* without it landing in a layer.

### `--network=host` is Linux-only

On Windows it is silently not what you want — ports must be mapped explicitly:

```powershell
docker run -p 9090:9090 <image>
```

And from inside a container, `127.0.0.1` is the *container's* loopback, not the
host's. To reach a service running on the host, use the Docker Desktop-provided
name:

```
host.docker.internal
```

### Heavy Windows container workloads

Windows containers do not get the host's full memory by default. For a heavy
build or test run:

```powershell
docker run --memory=48g <image>
```

### DNS: "could not resolve host" inside containers

Edit `C:\ProgramData\Docker\config\daemon.json`:

```json
{
  "experimental": false,
  "hosts": ["npipe:////./pipe/docker_engine_windows"],
  "dns": ["8.8.8.8", "8.8.4.4"]
}
```

```powershell
Restart-Service -Name com.docker.service
Restart-Service docker
```

Those two service names, and the `hosts` line, are Docker Desktop's. On a
Stevedore host leave the `hosts` line out: it is exactly the Fix 1 conflict and
stops the `stevedore` service from starting. Restart `stevedore` instead, then
re-check the CNI subnet: a dockerd start can move the nat network
([`windows-host-setup.md`](windows-host-setup.md) § A5).

### When the service is wedged

On Docker Desktop (a Stevedore host restarts `stevedore`, as above):

```powershell
Restart-Service -Name com.docker.service
Restart-Service docker
```

If the daemon is unreachable rather than merely stopped, the desktop app's
backend processes have to go first:

```powershell
'com.docker.backend','Docker Desktop','dockerd' | ForEach-Object {
    Get-Process -Name $_ -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 5
Start-Process -FilePath "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
```

A version rollback is a legitimate fix when an update breaks the lane — the
installer accepts an explicit downgrade:

```powershell
.\DockerDesktopInstaller.exe install --disable-version-check
```

### Two container-image gotchas

- **MSBuild Tools** are not in the base images; see
  [Microsoft's build-tools container guidance](https://learn.microsoft.com/en-us/visualstudio/install/build-tools-container?view=vs-2022).
- **WinGet is only available on Windows Server Core 2025 images.** Anything
  older has to install packages another way.
