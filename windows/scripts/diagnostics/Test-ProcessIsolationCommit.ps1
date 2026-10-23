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

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsDiagnostics.Common.psm1')
$Docker = Resolve-DiagnosticDocker -Docker $Docker

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dockerfile = Join-Path $scriptDir 'Dockerfile.isolation-probe'
if (-not (Test-Path $dockerfile)) { throw "probe Dockerfile missing: $dockerfile" }
$probeTag = 'local/isolation-probe:test'

# Continue, so docker's stderr never throws; the exit code decides.
$ErrorActionPreference = 'Continue'

Write-DiagnosticHostEnvironment -Docker $Docker -Base $Base -ImageLabel 'Probe base img '

# --- 1. CONTROL: process-isolation RUN (should always pass) ---
Write-DiagnosticHeading 'CONTROL: docker run --isolation process (expected: PASS)'
$null = Invoke-DiagnosticControl -Docker $Docker -Base $Base -Command @('cmd', '/c', 'echo run-ok & echo NPROC=%NUMBER_OF_PROCESSORS%') `
    -Marker 'run-ok' -SuccessDetail 'process isolation runs' -FailureDetail 'process isolation cannot even RUN here'

# --- 2. VERDICT: process-isolation BUILD+COMMIT (the operation that fails today) ---
Write-DiagnosticHeading 'VERDICT: docker build --isolation process (SUCCESS => bug is GONE)'
& $Docker image rm -f $probeTag 2>&1 | Out-Null
$result = Invoke-DiagnosticDocker -Docker $Docker -Arguments @(
    'build', '--isolation', 'process', '--no-cache', '--build-arg', "BASE=$Base", '--build-arg', "COUNT=$Count",
    '-t', $probeTag, '-f', $dockerfile, $scriptDir)
$buildExit = $result.Code
$joined = $result.Text
$hitKnownBug = $joined -match 'ActivateLayer|0x20|DO_NOT_DETACH|0x801f0010|file used by another process'

$verdict = Write-DiagnosticVerdict -Passed ($buildExit -eq 0) -KnownBug $hitKnownBug -Success @(
    'BUG GONE: `docker build --isolation process` committed a layer successfully!'
    'This host can commit process-isolated layers — the shape the BuildKit lane needs.'
    '      The classic run+commit workaround this probe used to gate is gone with build.ps1.') -Present @(
    'BUG PRESENT: the known wcifs/ActivateLayer commit failure still occurs on this version.'
    'Keep using the run+commit workaround (docker run --isolation hyperv --cpu-count N + docker commit).') -Failure ("BUILD FAILED (exit {0}) but NOT with the known signature -- investigate; do not assume the bug is fixed." -f $buildExit)
if ($verdict -eq 0) { & $Docker image rm -f $probeTag 2>&1 | Out-Null }
exit $verdict
