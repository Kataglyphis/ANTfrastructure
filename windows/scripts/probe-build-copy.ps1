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
$probeRef = 'docker.io/local/kataglyphis:probe-build-copy'
$failedLanes = @()

Write-Host '== buildkit (buildctl) lane ==' -ForegroundColor Cyan
$buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
if (Test-Path $buildctl) {
    # Comma-attribute native args MUST be double-quoted strings: pwsh parses
    # the bareword form (--output type=image,name=$ref) as an ArrayLiteral and
    # hands the native exe the VERBATIM SOURCE TEXT - no variable expansion
    # (before 2026-08-10 buildctl exported into a directory literally named
    # '$outDir'). Regression pin: tests/Native.ArgQuoting.Tests.ps1.
    & $buildctl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local "context=$probeDir" --local "dockerfile=$probeDir" `
        --output "type=image,name=$probeRef,unpack=true" 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
    Write-Host ("buildkit exit=" + $LASTEXITCODE)
    if ($LASTEXITCODE -ne 0) { $failedLanes += 'buildkit' }
} else {
    Write-Host 'buildctl.exe not found - skipping buildkit lane' -ForegroundColor Yellow
}

if ($Heavy) {
    Write-Host '== buildkit heavy-parent lane (RUN 2x100MB, then COPY) ==' -ForegroundColor Cyan
    if (Test-Path $buildctl) {
        & $buildctl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
            --local "context=$probeDir" --local "dockerfile=$probeDir" `
            --opt 'filename=Dockerfile.heavy' --no-cache `
            --output "type=image,name=$probeRef-heavy,unpack=true" 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
        Write-Host ("buildkit-heavy exit=" + $LASTEXITCODE)
        if ($LASTEXITCODE -ne 0) { $failedLanes += 'buildkit-heavy' }
    } else {
        Write-Host 'buildctl.exe not found - skipping heavy lane' -ForegroundColor Yellow
    }
}

if ($Docker) {
    Write-Host '== docker-classic (legacy builder) lane ==' -ForegroundColor Cyan
    # NOT $docker: variable names are case-insensitive, so that is the
    # [switch]$Docker parameter itself, and assigning a string to the
    # switch-constrained variable throws "Cannot convert ... String to ...
    # SwitchParameter" - this lane had never run until 2026-08-10.
    # Regression pin: tests/Native.ArgQuoting.Tests.ps1.
    $dockerExe = "$env:ProgramFiles\Stevedore\bin\docker.exe"
    if (Test-Path $dockerExe) {
        & $dockerExe build -t local/test:probe-build-copy $probeDir 2>&1 | Select-Object -Last 6 | ForEach-Object { Write-Host $_ }
        Write-Host ("docker exit=" + $LASTEXITCODE)
        if ($LASTEXITCODE -ne 0) { $failedLanes += 'docker-classic' }
    } else {
        Write-Host 'docker.exe not found - skipping docker lane' -ForegroundColor Yellow
    }
}

Write-Host ''
if ($failedLanes.Count -gt 0) {
    Write-Host ("PROBE FAILED (" + ($failedLanes -join ', ') + "): the build-COPY defect (or a lane-specific break) is present on this host.") -ForegroundColor Red
    exit 1
}
Write-Host 'PROBE OK: every attempted lane committed all layers (healthy host).' -ForegroundColor Green
exit 0
