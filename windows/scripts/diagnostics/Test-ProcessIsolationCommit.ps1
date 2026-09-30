# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Re-tests whether `docker build --isolation process` can commit a file-writing layer on this host.
.DESCRIPTION
    Run after any engine, Windows or base-image upgrade; the failure is the host/base OS build skew in wcifs.
    See docs/windows-build-lanes.md § Re-testing process isolation on new versions (is the bug gone yet?).
.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, the Stevedore locations, then PATH.
.PARAMETER Base
    Probe base image; a base whose build matches the host's is one of the only real fixes.
.PARAMETER Count
    Number of 2 MB files the probe writes (default 50, ~100 MB, already enough to reproduce).
.EXAMPLE
    .\windows\scripts\diagnostics\Test-ProcessIsolationCommit.ps1 -Base mcr.microsoft.com/windows/servercore:ltsc2027
#>
[CmdletBinding()]
param(
    [string]$Docker,
    [string]$Base  = 'mcr.microsoft.com/windows/servercore:ltsc2025',
    [int]$Count    = 50
)

# Resolve docker.exe
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1')
if (-not $Docker) { $Docker = Get-PreferredToolPath -CommandName 'docker' -CandidatePaths @($env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe") }
if (-not $Docker) { throw 'docker.exe not found. Pass -Docker <path>.' }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dockerfile = Join-Path $scriptDir 'Dockerfile.isolation-probe'
if (-not (Test-Path $dockerfile)) { throw "probe Dockerfile missing: $dockerfile" }
$probeTag = 'local/isolation-probe:test'

# Continue, so docker's stderr never throws; the exit code decides.
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
    Write-Host 'This host can commit process-isolated layers — the shape the BuildKit lane needs.' -ForegroundColor Green
    Write-Host '      The classic run+commit workaround this probe used to gate is gone with build.ps1.' -ForegroundColor Green
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

