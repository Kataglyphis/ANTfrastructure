# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Snapshots the host's Local Session Manager idle and during a container hang, in case a wedged host broker is the cause.
.DESCRIPTION
    Attaches non-invasively only (deliberately no -Invasive), so it cannot take down a process the session stack needs.
    Findings go to out/lsm-attach/.
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Only the setup is shared with the other LSM probes; the cdb command strings stay here.
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSiloProbe.Common.psm1') -Force -DisableNameChecking

$OutDir = Initialize-LsmProbeOutDir -OutDir $OutDir
$cdb = Get-CdbPath

$svc = Get-CimInstance Win32_Service -Filter "Name='LSM'" -ErrorAction SilentlyContinue
if (-not $svc -or -not $svc.ProcessId) { throw 'host LSM service not found or not running' }
$hostLsmPid = [int]$svc.ProcessId
Write-Host "host LSM: pid $hostLsmPid (state $($svc.State))"

# A protected process would refuse even a read-only attach; say so plainly.
$prot = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LSM' -Name LaunchProtected -ErrorAction SilentlyContinue
if ($prot -and $prot.LaunchProtected) { throw "LSM runs protected (LaunchProtected=$($prot.LaunchProtected)); no attach possible" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"

# No .printf: it swallows the semicolons after it; gServer holds the session counters (a blind read, no private symbols).
$cmds = @(
    '.reload /f'
    '~*kv'
    '!locks'
    '!cs -l -o'
    'x lsm!*Container*'
    'x lsm!ContainerSessionServer::gServer'
    'dps poi(lsm!ContainerSessionServer::gServer) L20'
    'dd lsm!ContainerSessionServer::gServer L10'
    'qd'
) -join '; '

function Invoke-HostLsmSnapshot([string]$tag) {
    $out = Join-Path $OutDir "host-lsm-$hostLsmPid-$stamp-$tag.txt"
    & $cdb -pv -p $hostLsmPid -y $sym -c $cmds > $out 2>&1
    $stacks = @(Select-String -Path $out -Pattern 'Call Site' -ErrorAction SilentlyContinue).Count
    $bad = @(Select-String -Path $out -Pattern 'Bad register|Syntax error' -ErrorAction SilentlyContinue).Count
    Write-Host ("  [{0}] stacks={1} errors={2} -> {3}" -f $tag, $stacks, $bad, (Split-Path $out -Leaf))
    if ($stacks -lt 2 -or $bad -gt 0) { Write-Warning "[$tag] cdb produced no usable output - a quiet log here is NOT evidence of a healthy host." }
    return $out
}

# An idle snapshot alone proves nothing, so compare it with one taken during a hang.
Write-Host "snapshot A (idle) ..."
$logA = Invoke-HostLsmSnapshot 'A-idle'

$baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
Start-SiloBaitContainer -Tag 'hostlsm'
Write-Host "bait started; waiting for its silo ..."

# 180 s, not 900: this bait just started, so a silo that has not appeared by then is not coming.
if (-not (Wait-ForNewSilo -BaselinePid $baseWininit -TimeoutSec 180 -PollSec 2)) {
    Write-Warning 'no silo appeared; snapshot B will be another idle sample'
}
Start-Sleep -Seconds 20   # land inside the ~141 s stall, past silo creation

Write-Host "snapshot B (container hanging) ..."
$log = Invoke-HostLsmSnapshot 'B-hang'

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null

Write-Host "`n--- idle vs hanging ---"
function Get-Frames([string]$path) {
    @(Select-String -Path $path -Pattern '!' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Line -match ':\s+([A-Za-z_][\w:!`~]+\+0x[0-9a-f]+)\s*$') { $Matches[1] -replace '\+0x[0-9a-f]+$', '' } }) | Sort-Object -Unique
}
$fa = Get-Frames $logA
$fb = Get-Frames $log
$new = @($fb | Where-Object { $_ -notin $fa })
Write-Host ("  frames only present while a container hangs: {0}" -f $new.Count)
$new | Where-Object { $_ -like 'lsm!*' -or $_ -like '*Container*' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }

foreach ($pat in 'AskForSession', 'ContainerSession', 'LockCount', 'OwningThread') {
    $a = @(Select-String -Path $logA -Pattern $pat -ErrorAction SilentlyContinue).Count
    $b = @(Select-String -Path $log -Pattern $pat -ErrorAction SilentlyContinue).Count
    Write-Host ("  {0,-18} idle={1}  hanging={2}" -f $pat, $a, $b)
}
Write-Host "`n  gServer dump: compare the two files by hand - a counter that only" -ForegroundColor DarkGray
Write-Host "  moves up across container starts is the hypothesis to confirm." -ForegroundColor DarkGray
Write-Host "`nSaved: $log" -ForegroundColor Green
