# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Names the object LSM waits on during the container boot hang: attaches to a
    fresh silo's DcomLaunch svchost and enumerates its handles while the wait is
    live. The companion Get-LsmWaitstack.ps1 proves the wait is static;
    this one identifies what is being waited FOR.

.DESCRIPTION
    Run ELEVATED while container starts are happening. Waits for a new silo
    (process tree: fresh wininit.exe -> its services.exe -> their svchosts),
    picks the svchost whose stack carries lsm!, and runs cdb against it.

    Attaches NON-INVASIVELY (-pv) by default: the debugger never controls the
    target, so it cannot kill the container. -Invasive adds a controlling
    attach (quit-and-detach) for the commands noninvasive mode refuses.

    Output goes to out/lsm-attach/ and is made readable for the invoking user,
    because an elevated writer otherwise leaves it SYSTEM-owned.

.EXAMPLE
    pwsh -File windows\scripts\diagnostics\Get-LsmWaitObject.ps1
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

# Setup only (cdb discovery, out dir, silo descent) is shared with the other
# LSM probes; the !handle enumeration below stays here.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir
$cdb = Get-CdbPath
Write-Host "cdb: $cdb"

# Same silo detection as Get-LsmWaitstack.ps1: Win32_Process.ExecutablePath
# and .CommandLine are EMPTY for silo processes even elevated, so go by tree.
$baseWininit = Get-WininitProcessId
Write-Host "Baseline: $($baseWininit.Count) wininit. Waiting for a NEW silo (max $WaitForSiloSec s)..."

$newWininit = Wait-ForNewSilo -BaselineProcessId $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 3
if (-not $newWininit) { throw 'No new silo appeared - start a RUN-bearing build or probe and retry.' }

$siloServices = Get-SiloServicesProcess -WininitProcessId $newWininit.ProcessId
if (-not $siloServices) { throw "silo wininit $($newWininit.ProcessId) has no services.exe child" }

$svchosts = @(Get-SiloSvchost -ServicesProcessId $siloServices.ProcessId)
if (-not $svchosts) { throw "silo services $($siloServices.ProcessId) spawned no svchost" }
Write-Host ("silo svchosts: {0}" -f (($svchosts.ProcessId) -join ', '))

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"
$attach = if ($Invasive) { '-p' } else { '-pv', '-p' }

# The LSM host is whichever svchost carries lsm! on a stack. Probe each, then
# enumerate handles on the hit: the named event is the answer we are after.
$found = $false
foreach ($p in $svchosts) {
    $log = Join-Path $OutDir "attach-$($p.ProcessId)-$stamp.txt"
    Write-Host "  probing pid $($p.ProcessId) -> $log"
    $cmds = '.reload /f; ~*kb; !handle 0 f Event; !handle 0 f; qd'
    & $cdb @attach $p.ProcessId -y $sym -c $cmds > $log 2>&1
    if (Select-String -Path $log -Pattern 'lsm!CService::Start' -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "  >>> LSM host found: pid $($p.ProcessId)" -ForegroundColor Green
        $found = $true
    }
}
if (-not $found) { Write-Warning 'No svchost showed lsm!CService::Start - the hang window may have passed; retry on the next container.' }

# An elevated writer leaves these SYSTEM-owned; hand them back to the caller.
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null
Write-Host "Logs in $OutDir (readable by $me). Look for named Event objects beside the lsm! stack." -ForegroundColor Green
