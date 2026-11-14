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

## Stevedore disk inventory

From an elevated PowerShell 7 session, run the read-only inventory before deciding
what can be reclaimed:

```pwsh
.\windows\scripts\host\Get-StevedoreInventory.ps1
```

It reports filesystem free space, BuildKit disk usage, and the images and
containers in the BuildKit containerd namespace. `nerdctl` needs elevation on
the reference host. Use `-StevedoreNamespace`, `-BuildkitAddress`,
`-ContainerdAddress`, `-NerdctlPath` and `-BuildctlPath` for a different host;
the defaults point to the Stevedore installation and named pipes. A failed probe
returns a nonzero exit code, so a partial inventory is not a complete report.
Shared layers can remain pinned by image tags, while pruning build cache can
make later builds slower. Cleanup targets use GiB; the canonical script rounds up
to decimal MB for BuildKit. Its exit code alone does not prove enough space is free. Review the [store GC guidance](windows-build-lanes.md)
and the [sanctioned cleanup tool](windows-builds.md#clear-diskspaceps1) before
removing anything.

## Delegated maintenance and new hosts

### Availability and verified limits

The delegated cleanup is a **local pilot, not a portable feature installed by a
fresh clone or `Install-NewHost.ps1`**. Its preparation and tests currently live
in ignored `logs/handoff/stevedore-auto-cleanup/` on the provisioned machine.
Those files are not distributed by this repository. Copying their old installer
is not a new-host setup: its reviewed bundle contains a particular user SID,
paths and file hashes; idle recovery also expects six cache mounts and a specific
service topology. Fresh or different hosts need their own reviewed configuration
and acceptance. A portable installer remains an open backlog item.

Two fixed, on-demand Task Scheduler actions were verified on 2026-11-14:

| Task under `\ANTfrastructureMaintenance\` | Trigger and identity | Fixed scope |
| --- | --- | --- |
| `RegularCache` | Agent or operator starts it; runs as SYSTEM | Preview, then canonical unused regular-cache cleanup with a 100-GiB target; preserves image tags and compiler-cache mounts |
| `IdleRecovery` | Agent or operator starts it; runs as SYSTEM | On proven idle state, restore BuildKit and dependent Stevedore; compare images, mounts, containerd PID and CNI; no pruning |

This is not a timer, a low-space watcher, or an automatic call from every build.
The separate BuildKit daemon GC policy is described in the
[host setup](windows-host-setup.md#c3-deploy-the-gc-policy--build-history-cap-required--not-optional-tuning).
Normal-user starts work because an administrator once installed protected code
and granted that user read/execute permission on the fixed tasks. No unrestricted
administrator rights, writable SYSTEM scripts or arbitrary task arguments are
granted. Updating pinned tools or protected task files needs another reviewed
administrator installation.

The actual pilot recovery released 31 held references. Its following regular
cleanup increased filesystem free space by 10.03 GiB; 27 image identities and six
compiler-cache mounts were unchanged, and both workers and scheduler results were
zero. Only 14.43 GiB remained free, so the 100-GiB target was **not met**. A busy-client
attempt also refused before Apply. These are single-host results, not clean-host
or universal reliability evidence. In-use state, unknown responses, changed IDs,
service drift or changed tool hashes must stop maintenance.

### Operating an already provisioned pilot

Keep other sessions' container work paused; the idle probes are observations,
not a machine-wide lock. From the original pilot checkout, a normal PowerShell 7
session can submit the existing cleanup:

```pwsh
pwsh -NoProfile -File .\logs\handoff\stevedore-auto-cleanup\Start-DelegatedCleanup.ps1
```

If a completed build leaves only immutable/shared regular references held, the
separately approved recovery can be submitted first:

```pwsh
pwsh -NoProfile -File .\logs\handoff\stevedore-auto-cleanup\idle-recovery-20261114\Start-IdleRecovery.ps1
```

Submission is not completion. Read the new run under
`C:\Program Files\ANTfrastructure Maintenance\logs\`: cleanup writes `latest.json`,
recovery `latest-recovery.json`, each pointing to its detailed run directory.
Require a run started after submission, worker `raw_exit = 0`, scheduler
`LastTaskResult = 0`, no running instance, and matching before/after image and
cache identities. Recovery additionally needs unchanged containerd PID and
successful network validation. Its success precedes a separate regular cleanup;
it is not itself proof of space reclaimed. Measure current free bytes against
the next build's unchanged admission limit before restarting that build.

When tags hold all remaining shared layers, another cache-only run cannot promise
more space. Image retirement is a separate reviewed selection with full expected
IDs; compiler caches and unrelated images stay protected. Do not repeat an
exhausted prune, lower a disk guard, kill a live build or restart containerd to
make the space check pass.

### Bringing another machine into service

1. Complete [Windows host bring-up](windows-host-setup.md), including daemon GC
   sizing, endpoints, CNI and host checks. Do not transplant the old machine's
   task XML, user SID, PowerShell installation path or installed manifests.
2. Until a portable delegation package is shipped, use the versioned
   [inventory](#stevedore-disk-inventory) and
   [canonical cleanup](windows-builds.md#clear-diskspaceps1) from an actual
   **Administrator PowerShell 7** at the new checkout root. Review the inventory
   and establish idle state, then preview:

   ```pwsh
   pwsh -NoProfile -File .\windows\scripts\host\Clear-DiskSpace.ps1 -StevedoreOnly -RegularCache -KeepGB 100
   if ($LASTEXITCODE -ne 0) { throw 'Cleanup preview failed.' }
   ```

   After reviewing that preview, apply only the same cache scope:

   ```pwsh
   pwsh -NoProfile -File .\windows\scripts\host\Clear-DiskSpace.ps1 -StevedoreOnly -RegularCache -KeepGB 100 -Apply
   if ($LASTEXITCODE -ne 0) { throw 'Cleanup failed; retain its diagnostics.' }
   Get-PSDrive -Name C | Select-Object Name, Free
   ```

   Keep the terminal output or a transcript in the new checkout's logs. Use the
   documented daemon address overrides if that host differs. Preview and Apply
   retain their own refusal checks; exit zero alone is not a capacity receipt.
3. Before claiming delegation on that machine, provide a versioned installer
   closure, derive its local user/paths/tools and preservation baseline, install
   once with UAC/admin approval, and prove the first start from a genuinely
   non-elevated session. Verify protected file/task ACLs, hashes, fixed actions,
   fresh logs, idle refusal, preservation and measured capacity there. The pilot's
   tests and old receipts do not replace that new-host test.

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
