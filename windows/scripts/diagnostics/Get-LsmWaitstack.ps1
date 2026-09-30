# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Dumps a fresh silo's first svchosts twice, 30 s apart, while LSM hangs START_PENDING, to prove the wait is static.
.DESCRIPTION
    Run elevated during a build; see docs/failure-modes.md § Every RUN step reports `DONE 2841.2s`.
    Analyse in WinDbg with .opendump, !runaway and ~*kb: the LSM thread's wait object names the silent component.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    # How long to wait for a fresh silo before giving up.
    [int]$WaitForSiloSec = 900
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only the setup is shared with the other LSM probes; this one writes .dmp files, so it keeps its own subdirectory.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir -DefaultSubPath 'out\lsm-dumps'

$baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
Write-Host "Baseline: $($baseWininit.Count) wininit (host + existing silos). Waiting for a NEW silo (max $WaitForSiloSec s)..."

$newWininit = Wait-ForNewSilo -BaselinePid $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 3
if (-not $newWininit) { throw 'No new silo appeared - is a build running? Start one RUN-bearing solve and retry.' }

# Only the early svchosts exist during the hang, and one of them hosts DcomLaunch and LSM.
$targets = @(Get-SiloSvchost -ServicesParentPid $newWininit.ProcessId | Select-Object -First 3)
if (-not $targets) { throw "silo wininit $($newWininit.ProcessId) spawned no svchost yet" }
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
