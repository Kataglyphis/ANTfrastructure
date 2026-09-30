#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# The 3-layer RUN+COPY probe to run before trusting a new Windows host; exports type=image like the chain, never type=local.

[CmdletBinding()]
param(
    # Also run the docker-classic legacy-builder probe (needs the dockerd service up).
    [switch]$Docker,
    # Also probe a COPY after a heavy RUN, which can fail at finalize while the light probe passes.
    [switch]$Heavy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$repoRoot = Split-Path (Split-Path $scriptAssetRoot -Parent) -Parent
$probeDir = Join-Path $repoRoot 'windows\scripts\diagnostics\probe-build-copy'
$probeAssets = @('Dockerfile', 'hello.txt') + $(if ($Heavy) { , 'Dockerfile.heavy' } else { @() })
foreach ($f in $probeAssets) {
    if (-not (Test-Path (Join-Path $probeDir $f))) { throw "probe asset missing: $f (expected under $probeDir)" }
}
# Every diagnostic tag shares the diag- prefix, so leftovers are one admin nerdctl sweep.
$probeRef = 'docker.io/local/kataglyphis:diag-probe-build-copy'
$failedLanes = @()
# Zero attempted lanes must never exit 0, or a botched install would certify the host healthy.
$attemptedLanes = @()
# Full output per lane on disk; the console shows only the tail.
$probeLogDir = Join-Path $repoRoot 'out\build-logs'
New-Item -ItemType Directory -Force -Path $probeLogDir | Out-Null
$probeStamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The chain's base digest, parsed without modules since this is the first script a new host runs.
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
    # Comma-attribute native args must be quoted elements: the bareword form passes the source text unexpanded.
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
# Inline candidate list: the first script a new host runs must stay module-free.
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
    # Not $docker, which is the [switch]$Docker parameter (names are case-insensitive); the module loads only in this lane.
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force -DisableNameChecking
    $dockerExe = Get-PreferredToolPath -CommandName 'docker' -CandidatePaths @($env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe")
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
