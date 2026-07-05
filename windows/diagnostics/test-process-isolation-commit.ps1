# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Re-test whether the Windows process-isolation LAYER-COMMIT bug still exists
    on this host. Run this after any Docker Engine / containerd / hcsshim /
    Windows / base-image upgrade to check if `docker build --isolation process`
    has become usable (which would let the WHOLE Windows build run at full CPU
    count instead of only media-core via the run+commit workaround).

.DESCRIPTION
    Background (see docs/windows-builds.md § Build isolation and CPU parallelism):
    on this host `docker build` is capped at 2 CPUs under Hyper-V isolation, and
    `docker build --isolation process` exposes all CPUs but CANNOT COMMIT a
    file-writing layer -- the wcifs minifilter refuses to detach the layer
    (ERROR_FLT_DO_NOT_DETACH 0x801f0010) and the commit dies with
    hcsshim::ActivateLayer 0x20 "file used by another process". Root cause is an
    OS-class mismatch: client host build (26200) vs Server base image (ltsc2025 /
    26100). See the windows-container-host-quirks memory for the full diagnosis.

    This script runs two checks against a tiny self-contained probe image
    (windows/diagnostics/Dockerfile.isolation-probe, ~100 MB layer, ~10s):

      1. CONTROL  -- `docker run --isolation process` (expected: always works).
      2. VERDICT  -- `docker build --isolation process` (the operation that fails
                     today). SUCCESS here => the bug is GONE on this version.

    It prints the exact Docker/containerd/host build numbers so you can record
    which versions changed behaviour, then a clear BUG GONE / BUG PRESENT verdict.

.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, then the Stevedore install
    locations, then docker on PATH (same resolution as windows/build.ps1).

.PARAMETER Base
    Base image for the probe (default: mcr.microsoft.com/windows/servercore:ltsc2025).
    Point this at a NEWER matching-build base image if one becomes available --
    a host-build-matching base is one of the only real fixes.

.PARAMETER Count
    Number of 2 MB files the probe writes (default 50 => ~100 MB layer). The bug
    reproduced even at 100 MB, so a bigger layer is not needed.

.EXAMPLE
    .\windows\diagnostics\test-process-isolation-commit.ps1

.EXAMPLE
    # Test a hypothetical newer base image whose build matches the host:
    .\windows\diagnostics\test-process-isolation-commit.ps1 -Base mcr.microsoft.com/windows/servercore:ltsc2027
#>
[CmdletBinding()]
param(
    [string]$Docker,
    [string]$Base  = 'mcr.microsoft.com/windows/servercore:ltsc2025',
    [int]$Count    = 50
)

# --- Resolve docker.exe (mirror windows/build.ps1's resolution order) ---
if (-not $Docker) {
    $candidates = @($env:DOCKER_EXE,
        'D:\Stevedore\bin\docker.exe',
        "$env:ProgramFiles\Stevedore\bin\docker.exe") | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path $c) { $Docker = $c; break } }
    if (-not $Docker) { $Docker = (Get-Command docker -ErrorAction SilentlyContinue).Source }
}
if (-not $Docker) { throw 'docker.exe not found. Pass -Docker <path>.' }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dockerfile = Join-Path $scriptDir 'Dockerfile.isolation-probe'
if (-not (Test-Path $dockerfile)) { throw "probe Dockerfile missing: $dockerfile" }
$probeTag = 'local/isolation-probe:test'

# Native stderr must NOT throw under PS 5.1: never run with EAP=Stop around the
# docker calls; always capture 2>&1 and branch on $LASTEXITCODE.
$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# --- Record the versions this result belongs to ---
Write-Head 'Environment (record these against the verdict)'
$hostBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
Write-Host ("Host           : {0} (build {1}.{2})" -f $hostBuild.ProductName, $hostBuild.CurrentBuildNumber, $hostBuild.UBR)
Write-Host ("Probe base img : {0}" -f $Base)
& $Docker version --format 'Docker Engine  : {{.Server.Version}} (API {{.Server.APIVersion}})' 2>&1 | Write-Host
& $Docker info --format 'containerd     : {{.ContainerdCommit.ID}}   default-isolation: {{.Isolation}}' 2>&1 | Write-Host

# --- 1. CONTROL: process-isolation RUN (should always pass) ---
Write-Head 'CONTROL: docker run --isolation process (expected: PASS)'
$runOut = & $Docker run --rm --isolation process $Base cmd /c "echo run-ok & echo NPROC=%NUMBER_OF_PROCESSORS%" 2>&1
$runExit = $LASTEXITCODE
$runOut | Write-Host
$controlPass = ($runExit -eq 0 -and ($runOut -join "`n") -match 'run-ok')
Write-Host ("CONTROL: {0}" -f $(if ($controlPass) { 'PASS (process isolation runs)' } else { 'FAIL (process isolation cannot even RUN here)' })) `
    -ForegroundColor $(if ($controlPass) { 'Green' } else { 'Red' })

# --- 2. VERDICT: process-isolation BUILD+COMMIT (the operation that fails today) ---
Write-Head 'VERDICT: docker build --isolation process (SUCCESS => bug is GONE)'
& $Docker image rm -f $probeTag 2>&1 | Out-Null
$buildOut = & $Docker build --isolation process --no-cache `
    --build-arg "BASE=$Base" --build-arg "COUNT=$Count" `
    -t $probeTag -f $dockerfile $scriptDir 2>&1
$buildExit = $LASTEXITCODE
$buildOut | Write-Host
$joined = ($buildOut -join "`n")
$hitKnownBug = $joined -match 'ActivateLayer|0x20|DO_NOT_DETACH|0x801f0010|file used by another process'

Write-Head 'RESULT'
if ($buildExit -eq 0) {
    Write-Host 'BUG GONE: `docker build --isolation process` committed a layer successfully!' -ForegroundColor Green
    Write-Host 'Next: you can now switch heavy build stages to process isolation for full-CPU builds.' -ForegroundColor Green
    Write-Host '      Retire the media-core run+commit workaround (Invoke-MediaCoreRunCommit in' -ForegroundColor Green
    Write-Host '      windows/build.ps1) once you have re-run the full build and confirmed parity.' -ForegroundColor Green
    Write-Host '      Update docs/windows-builds.md and the windows-container-host-quirks memory.' -ForegroundColor Green
    & $Docker image rm -f $probeTag 2>&1 | Out-Null
    exit 0
}
elseif ($hitKnownBug) {
    Write-Host 'BUG PRESENT: the known wcifs/ActivateLayer commit failure still occurs on this version.' -ForegroundColor Yellow
    Write-Host 'Keep using the run+commit workaround (docker run --isolation hyperv --cpu-count N + docker commit).' -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host ("BUILD FAILED (exit {0}) but NOT with the known signature -- investigate; do not assume the bug is fixed." -f $buildExit) -ForegroundColor Red
    exit 2
}
