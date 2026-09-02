# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Inspects the HOST's Local Session Manager. The container-side diagnosis
    stalled at "LSM waits for a session state that never arrives"; if the
    container's LSM is a client of the host's, a wedged host broker would
    explain every symptom at once.

.DESCRIPTION
    Both other diagnostics find their target through the silo (a fresh
    wininit.exe -> its services.exe -> their svchosts), so the host's own LSM
    has never been looked at. This attaches to it NON-INVASIVELY only: the
    debugger never controls the target, so it cannot take down a process the
    session stack depends on. There is deliberately no -Invasive switch.

    Needs no container and no timing window - the host LSM is always running.

    Findings go to out/lsm-attach/, readable by the caller.

.EXAMPLE
    pwsh -File windows\scripts\diagnostics\inspect-host-lsm.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutDir) {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $OutDir = Join-Path $repoRoot 'out\lsm-attach'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cdb = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter cdb.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -like '*Microsoft.WinDbg*amd64*' } | Select-Object -First 1
if (-not $cdb) { throw 'cdb.exe not found - winget install Microsoft.WinDbg' }

$svc = Get-CimInstance Win32_Service -Filter "Name='LSM'" -ErrorAction SilentlyContinue
if (-not $svc -or -not $svc.ProcessId) { throw 'host LSM service not found or not running' }
$hostLsmPid = [int]$svc.ProcessId
Write-Host "host LSM: pid $hostLsmPid (state $($svc.State))"

# A protected process would refuse even a read-only attach; say so plainly.
$prot = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LSM' -Name LaunchProtected -ErrorAction SilentlyContinue
if ($prot -and $prot.LaunchProtected) { throw "LSM runs protected (LaunchProtected=$($prot.LaunchProtected)); no attach possible" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "host-lsm-$hostLsmPid-$stamp.txt"
$sym = "srv*$OutDir\sym*https://msdl.microsoft.com/download/symbols"

# No .printf here: its comma-separated argument list swallows the following
# semicolons, and cdb then runs NOTHING after it ("Bad register error at
# '@r10; kv; ...'") - measured 2026-09-02, it cost a whole run's stacks and
# locks. Plain commands separated by ';' work.
#
# gServer is the process-wide ContainerSessionServer; dumping around it is a
# blind read (no private symbols) but the session counters that
# Increase/DecreaseTotalSessionCount maintain live in there.
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

Write-Host "attaching read-only (-pv) ..."
& $cdb.FullName -pv -p $hostLsmPid -y $sym -c $cmds > $log 2>&1

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $OutDir /grant "${me}:(OI)(CI)R" /T | Out-Null

Write-Host "`n--- what to look for ---"
# A run where the commands did not execute looks identical to a clean host, so
# check the evidence arrived before reading anything into it.
$stacks = @(Select-String -Path $log -Pattern 'Call Site' -ErrorAction SilentlyContinue).Count
$bad = @(Select-String -Path $log -Pattern 'Bad register|Syntax error' -ErrorAction SilentlyContinue).Count
Write-Host ("  thread stacks printed : {0}" -f $stacks)
if ($stacks -lt 2 -or $bad -gt 0) {
    Write-Warning "cdb produced no usable output ($bad command error(s)) - do NOT read 'no locks' as 'host is healthy'."
}
foreach ($pat in 'AskForSession', 'LockCount', 'OwningThread', 'Lock count', 'No locks') {
    $n = @(Select-String -Path $log -Pattern $pat -ErrorAction SilentlyContinue).Count
    Write-Host ("  {0,-22} {1} hit(s)" -f $pat, $n)
}
Write-Host "`nSaved: $log" -ForegroundColor Green
