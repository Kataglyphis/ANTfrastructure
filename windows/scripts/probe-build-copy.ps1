# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The 3-layer Windows-container build probe: FROM servercore:ltsc2025 + a RUN
# + a COPY. A healthy host commits BOTH layers; a host with the build-COPY
# defect (hcsshim::ActivateLayer 0x20 on buildkit / mkdir Volume\C:. on the
# docker legacy builder - see AGENTS.md Common Failure Modes "AMD Radeon host -
# faulty Adrenaline install"; root-caused 2026-08-09 to a bad AMD Adrenaline
# install, NOT the RDNA GPU) commits the RUN layer and fails on the COPY.
# 30 seconds, no admin,
# needs only a runnable buildkitd/buildctl. Docs reference this probe as "the
# 3-layer RUN+COPY probe" - run IT before trusting a new Windows host.
#
# The buildkit lane exports "type=image,...,unpack=true" - the SAME output path
# build-buildkit.ps1 uses - so a green probe covers layer commit AND the
# finalize/unpack reimport (the step that carried the 0x20 host-residual).
# Never "simplify" it to type=local: the local exporter cannot receive a
# Windows rootfs (dies mid-copy with "error from receiver: write ...\Boot\
# Fonts\<font>.ttf: file already closed", measured 2026-08-10) and on a healthy
# host that failure reads exactly like a host defect.
#
#   pwsh -File windows\scripts\probe-build-copy.ps1            # buildkit lane
#   pwsh -File windows\scripts\probe-build-copy.ps1 -Docker     # docker-classic lane too
#   pwsh -File windows\scripts\probe-build-copy.ps1 -Heavy      # + heavy-parent lane
#
# Exit code: 0 = every attempted lane committed all layers; 1 = any lane failed.

#requires -Version 7.0
[CmdletBinding()]
param(
    # Also run the docker-classic legacy-builder probe (needs the stevedore/dockerd service up).
    [switch]$Docker,
    # Also probe the HEAVY-PARENT shape (Dockerfile.heavy: a RUN writing 2x100MB,
    # then a COPY): on 2026-08-10 the light 3-layer probe was GREEN while the real
    # chain's first COPY-after-a-heavy-RUN died deterministically at finalize with
    # ActivateLayer 0x20 (child snapshot reimport; the fresh heavy parent layer
    # stays held). Ruled out live on the discovered host: Defender (full
    # exclusion set incl. MsMpEng), daemon state (containerd+buildkitd bounce),
    # poisoned cache (fresh IDs under --no-cache), time (a 90s settle layer's
    # own commit fails too) - a host-level hcs/filter hold. ~1 min extra.
    [switch]$Heavy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$probeDir = Join-Path $repoRoot 'windows\diagnostics\probe-build-copy'
$probeAssets = @('Dockerfile', 'hello.txt') + $(if ($Heavy) { , 'Dockerfile.heavy' } else { @() })
foreach ($f in $probeAssets) {
    if (-not (Test-Path (Join-Path $probeDir $f))) { throw "probe asset missing: $f (expected under $probeDir)" }
}
# On success the image stays in the containerd store (namespace buildkit; one
# tiny COPY layer on top of servercore, collected by the pinned gcpolicy).
# Inspecting/removing it needs admin nerdctl - see AGENTS.md nerdctl lane.
# diag- prefix (backlog #29): every diagnostic-minted tag shares one prefix,
# so incident-day debris is one admin sweep:
#   nerdctl --namespace buildkit images | findstr diag-   (then rmi)
$probeRef = 'docker.io/local/kataglyphis:diag-probe-build-copy'
$failedLanes = @()
# Lanes that actually RAN. Zero attempted lanes must NEVER exit 0: a botched
# Stevedore install (no buildctl/docker found) would otherwise certify the
# host healthy with no evidence (found by the 2026-08-10 review sweep).
$attemptedLanes = @()
# FULL lane output is persisted per lane (owner directive: never swallow
# logs); the console shows only the tail plus the log path.
$probeLogDir = Join-Path $repoRoot 'out\build-logs'
New-Item -ItemType Directory -Force -Path $probeLogDir | Out-Null
$probeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# Pin the probe base to the SAME digest the chain builds on (backlog #26) -
# a floating tag would certify a different servercore than the chain uses.
# Dependency-free parse (no module import in the first script a new host runs);
# falls back to the Dockerfile's tag default when versions.env is unreadable.
$probeBase = ''
$versionsEnv = Join-Path $repoRoot 'linux\scripts\01-core\versions.env'
if (Test-Path $versionsEnv) {
    $ltsc = ''
    $digest = ''
    foreach ($line in Get-Content $versionsEnv) {
        if ($line -match '^WINDOWS_LTSC=(.+)$') { $ltsc = $Matches[1].Trim() }
        elseif ($line -match '^WINDOWS_BASE_DIGEST=(.+)$') { $digest = $Matches[1].Trim() }
    }
    if ($ltsc -and $digest) { $probeBase = "mcr.microsoft.com/windows/servercore:ltsc$ltsc@$digest" }
}
$baseArgs = if ($probeBase) { @('--opt', "build-arg:BASE=$probeBase") } else { @() }
if ($probeBase) { Write-Host "probe base pinned: $probeBase" -ForegroundColor DarkGray }

function Invoke-ProbeLane {
    # One lane runner (backlog #9): exe check, per-lane Tee log, tail echo,
    # exit report, attempted/failed bookkeeping. This was the same 9-line
    # shape hand-rolled three times - the duplication that let the -Docker
    # lane rot unnoticed until 2026-08-10.
    # Comma-attribute native args MUST arrive as quoted array elements: the
    # bareword form (--output type=image,name=$ref) parses as an ArrayLiteral
    # and hands the exe the VERBATIM SOURCE TEXT - no variable expansion.
    # Regression pin: tests/Native.ArgQuoting.Tests.ps1.
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    if (-not $Exe) {
        Write-Host "$Name lane tool not found - skipping" -ForegroundColor Yellow
        return
    }
    $script:attemptedLanes += $Name
    $laneLog = Join-Path $script:probeLogDir "probe-build-copy-$Name-$script:probeStamp.log"
    & $Exe @Arguments 2>&1 | Tee-Object -FilePath $laneLog | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
    Write-Host ("$Name exit=" + $LASTEXITCODE + "  [full log: $laneLog]")
    if ($LASTEXITCODE -ne 0) { $script:failedLanes += $Name }
}

Write-Host '== buildkit (buildctl) lane ==' -ForegroundColor Cyan
# Candidate list, not a single hardcoded path: D:\Stevedore is a supported
# layout (build-buildkit.ps1 resolves the same way; backlog item #2). Kept
# INLINE deliberately: this is the first script a new host runs, so it must
# stay module-free (Get-PreferredToolPath lives in a module).
$buildctl = @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$bkCommon = @('--addr', 'npipe:////./pipe/buildkitd', 'build', '--frontend', 'dockerfile.v0',
    '--local', "context=$probeDir", '--local', "dockerfile=$probeDir") + $baseArgs
Invoke-ProbeLane -Name 'buildkit' -Exe $buildctl -Arguments ($bkCommon + @('--output', "type=image,name=$probeRef,unpack=true"))

if ($Heavy) {
    Write-Host '== buildkit heavy-parent lane (RUN 2x100MB, then COPY) ==' -ForegroundColor Cyan
    Invoke-ProbeLane -Name 'buildkit-heavy' -Exe $buildctl -Arguments ($bkCommon + @('--opt', 'filename=Dockerfile.heavy', '--no-cache',
        '--output', "type=image,name=$probeRef-heavy,unpack=true"))
}

if ($Docker) {
    Write-Host '== docker-classic (legacy builder) lane ==' -ForegroundColor Cyan
    # NOT $docker: variable names are case-insensitive, so that is the
    # [switch]$Docker parameter itself, and assigning a string to the
    # switch-constrained variable throws "Cannot convert ... String to ...
    # SwitchParameter" - this lane had never run until 2026-08-10.
    $dockerExe = @("$env:ProgramFiles\Stevedore\bin\docker.exe", 'D:\Stevedore\bin\docker.exe') |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    $dockerBaseArgs = if ($probeBase) { @('--build-arg', "BASE=$probeBase") } else { @() }
    Invoke-ProbeLane -Name 'docker-classic' -Exe $dockerExe -Arguments (@('build') + $dockerBaseArgs + @('-t', 'local/test:diag-probe-build-copy', $probeDir))
}

Write-Host ''
if ($attemptedLanes.Count -eq 0) {
    Write-Host 'PROBE INCONCLUSIVE: no lane could run (buildctl/docker not found) - this is NOT a healthy verdict.' -ForegroundColor Red
    exit 1
}
if ($failedLanes.Count -gt 0) {
    Write-Host ("PROBE FAILED (" + ($failedLanes -join ', ') + "): the build-COPY defect (or a lane-specific break) is present on this host.") -ForegroundColor Red
    exit 1
}
Write-Host ('PROBE OK: every attempted lane committed all layers (healthy host): ' + ($attemptedLanes -join ', ')) -ForegroundColor Green
exit 0
