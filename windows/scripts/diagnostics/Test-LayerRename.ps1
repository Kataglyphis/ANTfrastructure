# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Re-tests the run-side wcifs bug: create-then-rename inside image-layer dirs of a process-isolated container fails.
.DESCRIPTION
    Run after any engine, Windows or base-image upgrade, beside Test-ProcessIsolationCommit.ps1 (the commit-side variant).
    See docs/windows-build-lanes.md § Run-side wcifs symptoms (process isolation).
.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, the Stevedore locations, then PATH.
.PARAMETER Base
    Image to probe; point it at the built developer image to probe its own layers.
.PARAMETER Count
    Create+rename iterations in the layer dir (default 25), since a single rename can slip through.
.EXAMPLE
    Import-Module .\windows\scripts\modules\WindowsContainerImage.Common.psm1
    .\windows\scripts\diagnostics\Test-LayerRename.ps1 -Base (Get-CiImageReference -Windows)
#>
[CmdletBinding()]
param(
    [string]$Docker,
    [string]$Base  = 'mcr.microsoft.com/windows/servercore:ltsc2025',
    [int]$Count    = 25
)

# Resolve docker.exe
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsScripts.Shared.psm1')
if (-not $Docker) { $Docker = Get-PreferredToolPath -CommandName 'docker' -CandidatePaths @($env:DOCKER_EXE, 'D:\Stevedore\bin\docker.exe', "$env:ProgramFiles\Stevedore\bin\docker.exe") }
if (-not $Docker) { throw 'docker.exe not found. Pass -Docker <path>.' }

# Continue, so docker's stderr never throws; the exit code decides.
$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# --- Record the versions this result belongs to ---
Write-Head 'Environment (record these against the verdict)'
$hostBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
Write-Host ("Host           : {0} (build {1}.{2})" -f $hostBuild.ProductName, $hostBuild.CurrentBuildNumber, $hostBuild.UBR)
Write-Host ("Probe image    : {0}" -f $Base)
& $Docker version --format 'Docker Engine  : {{.Server.Version}} (API {{.Server.APIVersion}})' 2>&1 | Write-Host
& $Docker info --format 'containerd     : {{.ContainerdCommit.ID}}   default-isolation: {{.Isolation}}' 2>&1 | Write-Host

# Rename-Item surfaces the same ERROR_PATH_NOT_FOUND that breaks git and Dart's File.renameSync.
$controlCmd = @'
$ErrorActionPreference = 'Stop'
try {
    New-Item -ItemType Directory -Path C:\probe-fresh -Force | Out-Null
    Set-Content -Path C:\probe-fresh\a.txt -Value probe
    Rename-Item -Path C:\probe-fresh\a.txt -NewName b.txt
    Write-Host 'control-ok'
} catch { Write-Host ("control-failed: " + $_.Exception.Message); exit 1 }
'@

$verdictCmd = @'
$ErrorActionPreference = 'Stop'
$dir = 'C:\Windows\Temp'
for ($i = 1; $i -le COUNT_PLACEHOLDER; $i++) {
    $src = Join-Path $dir ("wcifs-probe-{0}.txt" -f $i)
    try {
        Set-Content -Path $src -Value probe
        Rename-Item -Path $src -NewName ("wcifs-probe-{0}-renamed.txt" -f $i)
    } catch {
        Write-Host ("rename-failed at iteration {0}: {1}" -f $i, $_.Exception.Message)
        exit 1
    }
}
Write-Host 'rename-ok'
'@ -replace 'COUNT_PLACEHOLDER', $Count

$encode = { param($s) [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($s)) }

# --- 1. CONTROL: rename in a FRESH (sandbox-created) dir (expected: PASS) ---
Write-Head 'CONTROL: create+rename in a fresh directory (expected: PASS)'
$runOut = & $Docker run --rm --isolation process $Base pwsh -NoProfile -EncodedCommand (& $encode $controlCmd) 2>&1
$runExit = $LASTEXITCODE
$runOut | Write-Host
$controlPass = ($runExit -eq 0 -and ($runOut -join "`n") -match 'control-ok')
Write-Host ("CONTROL: {0}" -f $(if ($controlPass) { 'PASS (fresh dirs unaffected, as documented)' } else { 'FAIL (even fresh dirs broken -- different problem, investigate)' })) `
    -ForegroundColor $(if ($controlPass) { 'Green' } else { 'Red' })

# --- 2. VERDICT: rename loop in an image-LAYER dir (fails while bug present) ---
Write-Head ("VERDICT: {0}x create+rename in C:\Windows\Temp (SUCCESS => bug is GONE)" -f $Count)
$probeOut = & $Docker run --rm --isolation process $Base pwsh -NoProfile -EncodedCommand (& $encode $verdictCmd) 2>&1
$probeExit = $LASTEXITCODE
$probeOut | Write-Host
$joined = ($probeOut -join "`n")
$hitKnownBug = $joined -match 'rename-failed|PATH_NOT_FOUND|Could not find a part of the path'

Write-Head 'RESULT'
if ($probeExit -eq 0 -and $joined -match 'rename-ok') {
    Write-Host 'BUG GONE: create+rename inside an image-layer directory succeeded under process isolation!' -ForegroundColor Green
    Write-Host 'Next: re-check the commit-side variant (Test-ProcessIsolationCommit.ps1); if both pass,' -ForegroundColor Green
    Write-Host '      consumers no longer need the bind-mount workaround. Update docs/windows-builds.md' -ForegroundColor Green
    Write-Host '      (§ Run-side wcifs symptoms) and the windows-container-host-quirks memory.' -ForegroundColor Green
    exit 0
}
elseif ($hitKnownBug) {
    Write-Host 'BUG PRESENT: the known run-side wcifs rename failure still occurs on this version.' -ForegroundColor Yellow
    Write-Host 'Keep the consumer workaround: bind-mount source trees from plain NTFS (Dev Drive needs' -ForegroundColor Yellow
    Write-Host '`fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"` once, elevated) and avoid git/rename' -ForegroundColor Yellow
    Write-Host 'operations in image-layer directories.' -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host ("PROBE FAILED (exit {0}) but NOT with the known signature -- investigate; do not assume either way." -f $probeExit) -ForegroundColor Red
    exit 2
}

