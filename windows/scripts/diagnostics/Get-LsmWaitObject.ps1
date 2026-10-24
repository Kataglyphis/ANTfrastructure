# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Names the object LSM waits on during the container boot hang by enumerating the silo LSM svchost's handles.
.DESCRIPTION
    Run elevated while containers start; attaches non-invasively (-pv) by default so it cannot kill the container.
    Output goes to logs/lsm-attach/.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$WaitForSiloSec = 900,
    # Controlling attach; needed if noninvasive mode refuses !handle.
    [switch]$Invasive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir
$cdb = Get-CdbPath
Write-Host "cdb: $cdb"

# Silo processes have empty ExecutablePath/CommandLine even elevated, so only a new wininit.exe identifies one.
$baseWininit = @(Get-SiloWininitId)
Write-Host "Baseline: $($baseWininit.Count) wininit. Waiting for a NEW silo (max $WaitForSiloSec s)..."

$newWininit = Wait-ForNewSilo -BaselinePid $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 3
if (-not $newWininit) { throw 'No new silo appeared - start a RUN-bearing build or probe and retry.' }

$svchosts = @(Get-SiloSvchost -ServicesParentPid $newWininit.ProcessId)
if (-not $svchosts) { throw "silo wininit $($newWininit.ProcessId) spawned no svchost yet" }
Write-Host ("silo svchosts: {0}" -f (($svchosts.ProcessId) -join ', '))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The LSM host is whichever svchost carries lsm! on a stack.
$found = $false
foreach ($p in $svchosts) {
    $log = Join-Path $OutDir "attach-$($p.ProcessId)-$stamp.txt"
    Write-Host "  probing pid $($p.ProcessId) -> $log"
    $cmds = '.reload /f; ~*kb; !handle 0 f Event; !handle 0 f; qd'
    Invoke-SiloDebugger -CdbPath $cdb -ProcessId $p.ProcessId -OutDir $OutDir -Command $cmds -LogPath $log -Invasive:$Invasive
    if (Select-String -Path $log -Pattern 'lsm!CService::Start' -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "  >>> LSM host found: pid $($p.ProcessId)" -ForegroundColor Green
        $found = $true
    }
}
if (-not $found) { Write-Warning 'No svchost showed lsm!CService::Start - the hang window may have passed; retry on the next container.' }

# An elevated writer leaves these SYSTEM-owned; hand them back to the caller.
$me = Grant-SiloProbeReadAccess -OutDir $OutDir
Write-Host "Logs in $OutDir (readable by $me). Look for named Event objects beside the lsm! stack." -ForegroundColor Green
