# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Walks every process of a hung container's silo to see whether something upstream of LSM is stuck first.
.DESCRIPTION
    Starts its own bait container and attaches non-invasively to each silo process; a protected process's refusal is reported, not treated as a finding.
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [int]$WaitForSiloSec = 300
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only the setup is shared with the other LSM probes; the per-process attach stays here.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir
$cdb = Get-CdbPath

$baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
Start-SiloBaitContainer -Tag 'silo'
Write-Host 'bait started; waiting for its silo ...'

$newWininit = Wait-ForNewSilo -BaselinePid $baseWininit -TimeoutSec $WaitForSiloSec -PollSec 2
if (-not $newWininit) { throw 'No new silo appeared.' }
Write-Host "silo wininit: pid $($newWininit.ProcessId)"
Start-Sleep -Seconds 15   # land inside the ~141 s stall

# The silo's smss/csrss are not wininit's children, so they are matched by creation time.
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
        # 0n5 is a protected process refusing even a read-only attach, not a hang.
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
