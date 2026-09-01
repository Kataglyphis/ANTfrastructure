# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Captures the decisive evidence for the lost-shutdown-notification /
    LSM-boot-hang regression (docs/failure-modes.md "Every RUN step reports
    DONE 2841.2s"): full memory dumps of a fresh silo's earliest svchost
    processes while LSM hangs START_PENDING.

.DESCRIPTION
    Run ELEVATED while a container start is imminent - a running chain build
    starts one every few minutes, no extra probe needed. The script baselines
    the existing silo svchosts, waits for a NEW silo (svchost with a
    \Device\VhdHardDisk image path), then dumps its first svchosts twice,
    30 s apart, inside the ~140 s hang window. One of them hosts
    DcomLaunch/LSM; the second round proves the wait is static.

    Analysis (WinDbg, no admin): .opendump <file> -> !runaway ; ~*kb
    Find the LSM worker thread parked in KeWaitForSingleObject /
    WaitForSingleObjectEx - the wait OBJECT names the component that never
    signals, which is the open root-cause question.

    Uses comsvcs.dll MiniDump so no Sysinternals install is required;
    `procdump -ma` is the equivalent if present.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    # How long to wait for a fresh silo before giving up.
    [int]$WaitForSiloSec = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $OutDir = Join-Path $repoRoot 'out\lsm-dumps'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-SiloSvchost {
    Get-CimInstance Win32_Process -Filter "Name='svchost.exe'" |
        Where-Object { ($_.ExecutablePath -and $_.ExecutablePath -like '\Device\VhdHardDisk*') -or
                       ($_.CommandLine -and $_.CommandLine -like '*VhdHardDisk*') }
}

$baseline = @(Get-SiloSvchost | Select-Object -ExpandProperty ProcessId)
Write-Host "Baseline: $($baseline.Count) existing silo svchosts. Waiting for a NEW silo (max $WaitForSiloSec s)..."

$deadline = (Get-Date).AddSeconds($WaitForSiloSec)
$fresh = @()
while ((Get-Date) -lt $deadline) {
    $fresh = @(Get-SiloSvchost | Where-Object { $_.ProcessId -notin $baseline })
    if ($fresh.Count -ge 1) { break }
    Start-Sleep -Seconds 3
}
if (-not $fresh) { throw 'No new silo appeared - is a build running? Start one RUN-bearing solve and retry.' }

# The FIRST svchosts of the silo boot; one hosts DcomLaunch (and with it LSM).
$targets = $fresh | Sort-Object CreationDate | Select-Object -First 3
Write-Host ("New silo detected; dumping PIDs: {0}" -f (($targets.ProcessId) -join ', '))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($round in 1, 2) {
    foreach ($t in $targets) {
        $f = Join-Path $OutDir ("svchost-{0}-r{1}-{2}.dmp" -f $t.ProcessId, $round, $stamp)
        Write-Host "  dump $f"
        & rundll32.exe C:\Windows\System32\comsvcs.dll, MiniDump $t.ProcessId $f full
        Start-Sleep -Seconds 2
    }
    if ($round -eq 1) { Write-Host '30 s apart for the static-wait proof...'; Start-Sleep -Seconds 30 }
}
Write-Host "Done. Dumps in $OutDir - WinDbg: .opendump + ~*kb; find the LSM thread and its wait object." -ForegroundColor Green
