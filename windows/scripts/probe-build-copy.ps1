# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The 3-layer Windows-container build probe: FROM servercore:ltsc2025 + a RUN
# + a COPY. A healthy host commits BOTH layers; a host with the build-COPY
# defect (hcsshim::ActivateLayer 0x20 on buildkit / mkdir Volume\C:. on the
# docker legacy builder - see AGENTS.md Common Failure Modes "AMD RDNA3.5/RDNA4
# GPU host") commits the RUN layer and fails on the COPY. 30 seconds, no admin,
# needs only a runnable buildkitd/buildctl. Docs reference this probe as "the
# 3-layer RUN+COPY probe" - run IT before trusting a new Windows host.
#
#   pwsh -File windows\scripts\probe-build-copy.ps1            # buildkit lane
#   pwsh -File windows\scripts\probe-build-copy.ps1 -Docker     # docker-classic lane too

#requires -Version 7.0
[CmdletBinding()]
param(
    # Also run the docker-classic legacy-builder probe (needs the stevedore/dockerd service up).
    [switch]$Docker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$probeDir = Join-Path $repoRoot 'windows\diagnostics\probe-build-copy'
foreach ($f in 'Dockerfile', 'hello.txt') {
    if (-not (Test-Path (Join-Path $probeDir $f))) { throw "probe asset missing: $f (expected under $probeDir)" }
}
$outDir = Join-Path $repoRoot 'out\probe-build-copy'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host '== buildkit (buildctl) lane ==' -ForegroundColor Cyan
$buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
if (Test-Path $buildctl) {
    & $buildctl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local context=$probeDir --local dockerfile=$probeDir `
        --output type=local,dest=$outDir 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
    Write-Host ("buildkit exit=" + $LASTEXITCODE)
} else {
    Write-Host 'buildctl.exe not found - skipping buildkit lane' -ForegroundColor Yellow
}

if ($Docker) {
    Write-Host '== docker-classic (legacy builder) lane ==' -ForegroundColor Cyan
    $docker = "$env:ProgramFiles\Stevedore\bin\docker.exe"
    if (Test-Path $docker) {
        & $docker build -t local/test:probe-build-copy $probeDir 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
        Write-Host ("docker exit=" + $LASTEXITCODE)
    } else {
        Write-Host 'docker.exe not found - skipping docker lane' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Expected on a HEALTHY host: both lanes commit the COPY (exit 0).' -ForegroundColor Green
Write-Host 'Any lane failing on the COPY layer = the build-COPY defect is present here.' -ForegroundColor Yellow
