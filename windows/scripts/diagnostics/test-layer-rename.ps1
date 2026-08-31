# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Re-test whether the RUN-SIDE wcifs rename bug still exists on this host:
    create-then-rename of fresh files inside IMAGE-LAYER directories of a
    process-isolated container fails ERROR_PATH_NOT_FOUND. Run this after any
    Docker Engine / containerd / hcsshim / Windows / base-image upgrade,
    alongside test-process-isolation-commit.ps1 (the layer-COMMIT variant of
    the same wcifs bug).

.DESCRIPTION
    Background (see docs/windows-builds.md § Run-side wcifs symptoms): the same
    wcifs minifilter that breaks layer commits on this host/base skew (client
    26200 vs Server ltsc2025/26100) also breaks runtime file operations inside
    layer directories under process isolation. Create-then-RENAME of fresh
    files fails ERROR_PATH_NOT_FOUND, which breaks git init/clone/checkout
    ("could not write config file", "unable to write new index file") and
    Dart's File.renameSync (e.g. the sqlite3 package's native-asset hook).
    Plain copies and tar extractions succeed; fresh directories created in the
    sandbox (e.g. C:\probe-fresh) are unaffected; bind-mounted paths bypass
    wcifs entirely.

    This script runs two checks with `docker run --isolation process`:

      1. CONTROL  -- create+rename in a FRESH directory (expected: always works).
      2. VERDICT  -- create+rename loop in an image-layer directory
                     (C:\Windows\Temp). FAILURE here => the run-side bug is
                     still PRESENT; SUCCESS => it is GONE on this version.

.PARAMETER Docker
    Path to docker.exe. Defaults to $env:DOCKER_EXE, then the Stevedore install
    locations, then docker on PATH.

.PARAMETER Base
    Image to probe (default: mcr.microsoft.com/windows/servercore:ltsc2025).
    Point this at the built developer image to probe its layer dirs instead.

.PARAMETER Count
    Number of create+rename iterations in the layer dir (default 25). The bug
    is deterministic in hot paths but a single rename can slip through.

.EXAMPLE
    .\windows\scripts\diagnostics\test-layer-rename.ps1

.EXAMPLE
    # Probe the built image's own layers:
    .\windows\scripts\diagnostics\test-layer-rename.ps1 -Base ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
#>
[CmdletBinding()]
param(
    [string]$Docker,
    [string]$Base  = 'mcr.microsoft.com/windows/servercore:ltsc2025',
    [int]$Count    = 25
)

# --- Resolve docker.exe ($env:DOCKER_EXE, Stevedore install, then PATH) ---
if (-not $Docker) {
    $candidates = @($env:DOCKER_EXE,
        'D:\Stevedore\bin\docker.exe',
        "$env:ProgramFiles\Stevedore\bin\docker.exe") | Where-Object { $_ }
    foreach ($c in $candidates) { if (Test-Path $c) { $Docker = $c; break } }
    if (-not $Docker) { $Docker = (Get-Command docker -ErrorAction SilentlyContinue).Source }
}
if (-not $Docker) { throw 'docker.exe not found. Pass -Docker <path>.' }

# Native stderr must NOT throw under PS 5.1: never run with EAP=Stop around the
# docker calls; always capture 2>&1 and branch on $LASTEXITCODE.
$ErrorActionPreference = 'Continue'

function Write-Head($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# --- Record the versions this result belongs to ---
Write-Head 'Environment (record these against the verdict)'
$hostBuild = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
Write-Host ("Host           : {0} (build {1}.{2})" -f $hostBuild.ProductName, $hostBuild.CurrentBuildNumber, $hostBuild.UBR)
Write-Host ("Probe image    : {0}" -f $Base)
& $Docker version --format 'Docker Engine  : {{.Server.Version}} (API {{.Server.APIVersion}})' 2>&1 | Write-Host
& $Docker info --format 'containerd     : {{.ContainerdCommit.ID}}   default-isolation: {{.Isolation}}' 2>&1 | Write-Host

# Both probes run in-container PowerShell; Rename-Item surfaces the same
# ERROR_PATH_NOT_FOUND that breaks git and Dart's File.renameSync.
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
    Write-Host 'Next: re-check the commit-side variant (test-process-isolation-commit.ps1); if both pass,' -ForegroundColor Green
    Write-Host '      consumers no longer need the bind-mount workaround. Update docs/windows-builds.md' -ForegroundColor Green
    Write-Host '      (§ Run-side wcifs symptoms) and the windows-container-host-quirks memory.' -ForegroundColor Green
    exit 0
}
elseif ($hitKnownBug) {
    Write-Host 'BUG PRESENT: the known run-side wcifs rename failure still occurs on this version.' -ForegroundColor Yellow
    Write-Host 'Keep the consumer workaround: bind-mount source trees from plain NTFS (Dev Drive needs' -ForegroundColor Yellow
    Write-Host '`fsutil devdrv setfiltersallowed bindFlt, wcifs` once, elevated) and avoid git/rename' -ForegroundColor Yellow
    Write-Host 'operations in image-layer directories.' -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host ("PROBE FAILED (exit {0}) but NOT with the known signature -- investigate; do not assume either way." -f $probeExit) -ForegroundColor Red
    exit 2
}

