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

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsDiagnostics.Common.psm1')
$Docker = Resolve-DiagnosticDocker -Docker $Docker

# Continue, so docker's stderr never throws; the exit code decides.
$ErrorActionPreference = 'Continue'

Write-DiagnosticHostEnvironment -Docker $Docker -Base $Base

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
Write-DiagnosticHeading 'CONTROL: create+rename in a fresh directory (expected: PASS)'
$null = Invoke-DiagnosticControl -Docker $Docker -Base $Base -Command @('pwsh', '-NoProfile', '-EncodedCommand', (& $encode $controlCmd)) `
    -Marker 'control-ok' -SuccessDetail 'fresh dirs unaffected, as documented' -FailureDetail 'even fresh dirs broken -- different problem, investigate'

# --- 2. VERDICT: rename loop in an image-LAYER dir (fails while bug present) ---
Write-DiagnosticHeading ("VERDICT: {0}x create+rename in C:\Windows\Temp (SUCCESS => bug is GONE)" -f $Count)
$result = Invoke-DiagnosticDocker -Docker $Docker -Arguments @(
    'run', '--rm', '--isolation', 'process', $Base, 'pwsh', '-NoProfile', '-EncodedCommand', (& $encode $verdictCmd))
$probeExit = $result.Code
$joined = $result.Text
$hitKnownBug = $joined -match 'rename-failed|PATH_NOT_FOUND|Could not find a part of the path'

$verdict = Write-DiagnosticVerdict -Passed ($probeExit -eq 0 -and $joined -match 'rename-ok') -KnownBug $hitKnownBug -Success @(
    'BUG GONE: create+rename inside an image-layer directory succeeded under process isolation!'
    'Next: re-check the commit-side variant (Test-ProcessIsolationCommit.ps1); if both pass,'
    '      consumers no longer need the bind-mount workaround. Update docs/windows-builds.md'
    '      (§ Run-side wcifs symptoms) and the windows-container-host-quirks memory.') -Present @(
    'BUG PRESENT: the known run-side wcifs rename failure still occurs on this version.'
    'Keep the consumer workaround: bind-mount source trees from plain NTFS (Dev Drive needs'
    '`fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"` once, elevated) and avoid git/rename'
    'operations in image-layer directories.') -Failure ("PROBE FAILED (exit {0}) but NOT with the known signature -- investigate; do not assume either way." -f $probeExit)
exit $verdict
