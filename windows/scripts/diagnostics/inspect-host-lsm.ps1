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

function Invoke-HostLsmSnapshot([string]$tag) {
    $out = Join-Path $OutDir "host-lsm-$hostLsmPid-$stamp-$tag.txt"
    & $cdb.FullName -pv -p $hostLsmPid -y $sym -c $cmds > $out 2>&1
    $stacks = @(Select-String -Path $out -Pattern 'Call Site' -ErrorAction SilentlyContinue).Count
    $bad = @(Select-String -Path $out -Pattern 'Bad register|Syntax error' -ErrorAction SilentlyContinue).Count
    Write-Host ("  [{0}] stacks={1} errors={2} -> {3}" -f $tag, $stacks, $bad, (Split-Path $out -Leaf))
    if ($stacks -lt 2 -or $bad -gt 0) { Write-Warning "[$tag] cdb produced no usable output - a quiet log here is NOT evidence of a healthy host." }
    return $out
}

# An idle host LSM proves nothing: with no container starting, "no thread in
# AskForSession" is simply what idle looks like. Snapshot BEFORE and DURING a
# hang, and compare.
Write-Host "snapshot A (idle) ..."
$logA = Invoke-HostLsmSnapshot 'A-idle'

$buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
if (-not (Test-Path $buildctl)) { throw "buildctl not found at $buildctl" }
$nonce = Get-Date -Format 'yyyyMMddHHmmss'
$baitDir = Join-Path $env:TEMP "hostlsm-bait-$nonce"
New-Item -ItemType Directory -Force -Path $baitDir | Out-Null
# NONCE keeps the solve a cache MISS; a cached solve starts no container.
@'
ARG BASE
FROM ${BASE}
ARG NONCE
RUN echo bait-$NONCE > C:bait.txt
'@ | Set-Content (Join-Path $baitDir 'Dockerfile') -Encoding ascii
$baseWininit = @(Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Select-Object -ExpandProperty ProcessId)
Start-Process -FilePath $buildctl -WindowStyle Hidden -ArgumentList @(
    '--addr', 'npipe:////./pipe/buildkitd', 'build', '--frontend', 'dockerfile.v0'
    '--local', "context=$baitDir", '--local', "dockerfile=$baitDir"
    '--opt', 'build-arg:BASE=mcr.microsoft.com/windows/servercore:ltsc2025'
    '--opt', "build-arg:NONCE=$nonce", '--opt', 'image-resolve-mode=local'
    '--output', "type=image,name=docker.io/local/kataglyphis:diag-hostlsm-$nonce"
) | Out-Null
Write-Host "bait started; waiting for its silo ..."

$deadline = (Get-Date).AddSeconds(180)
$sawSilo = $false
while ((Get-Date) -lt $deadline) {
    if (Get-CimInstance Win32_Process -Filter "Name='wininit.exe'" | Where-Object { $_.ProcessId -notin $baseWininit }) { $sawSilo = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $sawSilo) { Write-Warning 'no silo appeared; snapshot B will be another idle sample' }
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
