# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Names the object LSM waits on during the container boot hang: attaches to a
    fresh silo's DcomLaunch svchost and enumerates its handles while the wait is
    live. The companion capture-lsm-waitstack.ps1 proves the wait is static;
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
    pwsh -File windows\scripts\diagnostics\name-lsm-wait-object.ps1
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

if (-not $OutDir) {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $OutDir = Join-Path $repoRoot 'out\lsm-attach'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cdb = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter cdb.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Where-Object { $_.DirectoryName -like '*Microsoft.WinDbg*amd64*' } | Select-Object -First 1
if (-not $cdb) { throw 'cdb.exe not found - install the WinDbg package (winget install Microsoft.WinDbg)' }
Write-Host "cdb: $($cdb.FullName)"

# Same silo detection as capture-lsm-waitstack.ps1: Win32_Process.ExecutablePath
# and .CommandLine are EMPTY for silo processes even elevated, so go by tree.
$baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
Write-Host "Baseline: $($baseWininit.Count) wininit. Waiting for a NEW silo (max $WaitForSiloSec s)..."

$deadline = (Get-Date).AddSeconds($WaitForSiloSec)
$newWininit = $null
while ((Get-Date) -lt $deadline) {
    $newWininit = Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" |
        Where-Object { $_.ProcessId -notin $baseWininit } | Select-Object -First 1
    if ($newWininit) { break }
    Start-Sleep -Seconds 3
}
if (-not $newWininit) { throw 'No new silo appeared - start a RUN-bearing build or probe and retry.' }

$siloServices = $null
foreach ($i in 1..20) {
    $siloServices = Get-CimInstance Win32_Process -Filter "Name='services.exe' AND ParentProcessId=$($newWininit.ProcessId)" | Select-Object -First 1
    if ($siloServices) { break }
    Start-Sleep -Seconds 1
}
if (-not $siloServices) { throw "silo wininit $($newWininit.ProcessId) has no services.exe child" }

$svchosts = @()
foreach ($i in 1..20) {
    $svchosts = @(Get-CimInstance Win32_Process -Filter "Name='svchost.exe' AND ParentProcessId=$($siloServices.ProcessId)" | Sort-Object CreationDate)
    if ($svchosts.Count -ge 1) { break }
    Start-Sleep -Seconds 2
}
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
    & $cdb.FullName @attach $p.ProcessId -y $sym -c $cmds > $log 2>&1
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
