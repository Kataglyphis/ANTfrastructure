# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Walks EVERY process in a hung container's silo, not just the svchost that
    hosts LSM. Answers whether LSM waits because something upstream in the silo
    boot - smss, csrss, wininit, services, lsass - is stuck first.

.DESCRIPTION
    All previous probes went straight to the LSM svchost, so the processes that
    actually create the session were never looked at. This starts its own bait
    container, waits for the silo, and attaches NON-INVASIVELY to each of its
    processes in turn.

    csrss.exe and (on some builds) smss.exe run as protected processes and will
    refuse even a read-only attach; that is reported per process rather than
    treated as a finding.

.EXAMPLE
    pwsh -File windows\scripts\diagnostics\Get-SiloProcesses.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$WaitForSiloSec = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Setup only (cdb discovery, out dir, bait, silo wait) is shared with the other
# LSM probes; the per-process attach and its summary stay here.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir
$cdb = Get-CdbPath

$baseWininit = Get-WininitProcessId
Start-SiloBaitContainer -Tag 'silo' | Out-Null
Write-Host 'bait started; waiting for its silo ...'

$newWininit = Wait-ForNewSilo -BaselineProcessId $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 2
if (-not $newWininit) { throw 'No new silo appeared.' }
Write-Host "silo wininit: pid $($newWininit.ProcessId)"
Start-Sleep -Seconds 15   # land inside the ~141 s stall

# Collect the silo by descent from its wininit, plus the smss/csrss that were
# created alongside it (they are not its children).
$silo = [System.Collections.Generic.List[object]]::new()
$silo.Add($newWininit)
$services = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($newWininit.ProcessId)"
foreach ($s in $services) {
    $silo.Add($s)
    foreach ($c in Get-CimInstance Win32_Process -Filter "ParentProcessId=$($s.ProcessId)") { $silo.Add($c) }
}
$after = $newWininit.CreationDate.AddSeconds(-5)
foreach ($n in 'smss.exe', 'csrss.exe') {
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='$n'") {
        if ($p.CreationDate -ge $after) { $silo.Add($p) }
    }
}
Write-Host ("silo processes to inspect: {0}" -f $silo.Count)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add("silo of wininit $($newWininit.ProcessId), sampled $stamp")
$summary.Add('')

foreach ($p in $silo) {
    $log = Join-Path $OutDir "silo-$($p.Name)-$($p.ProcessId)-$stamp.txt"
    & $cdb -pv -p $p.ProcessId -y $sym -c '.reload /f; ~*kb; qd' > $log 2>&1
    $stacks = @(Select-String -Path $log -Pattern 'Call Site' -ErrorAction SilentlyContinue).Count
    if ($stacks -lt 1) {
        # smss/csrss/wininit/services are PPL - 0n5 here is the OS refusing a
        # read-only attach, not a hang. Only a kernel debugger sees these.
        $why = if (Select-String -Path $log -Pattern 'error 0n5|Access is denied|protected' -Quiet -ErrorAction SilentlyContinue) { 'attach refused - protected process (PPL)' } else { 'no stacks' }
        $summary.Add(("{0,-16} pid {1,-7} -- {2}" -f $p.Name, $p.ProcessId, $why))
        continue
    }
    # A thread that is NOT in an idle-worker wait is what we are hunting.
    $busy = @(Select-String -Path $log -Pattern 'Call Site' -Context 0, 1 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Context.PostContext } | Where-Object { $_ -notmatch 'NtWaitForWorkViaWorkerFactory|NtRemoveIoCompletion|NtWaitForMultipleObjects' })
    $summary.Add(("{0,-16} pid {1,-7} threads={2}  non-idle-first-frames={3}" -f $p.Name, $p.ProcessId, $stacks, $busy.Count))
    foreach ($fr in 'lsm!', 'smss!', 'csrss', 'winsrv', 'sxssrv', 'SessionState', 'Session') {
        $n = @(Select-String -Path $log -Pattern $fr -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { $summary.Add(("    {0,-14} {1} frame hit(s)" -f $fr, $n)) }
    }
}

$report = Join-Path $OutDir "silo-summary-$stamp.txt"
$summary | Tee-Object -FilePath $report
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null
Write-Host "`nSaved: $report" -ForegroundColor Green
