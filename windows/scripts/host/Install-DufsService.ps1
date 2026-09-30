#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Runs the sccache WebDAV endpoint as one ONSTART SYSTEM task, since a logon-bound one dies with the session silently.

[CmdletBinding()]
param(
    [string]$DufsExe = "$env:USERPROFILE\scoop\shims\dufs.exe",
    [string]$ServeDir = "$env:USERPROFILE\sccache-cache",
    [int]$Port = 5000,
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Assert-Elevated -Reason 'schtasks /RU SYSTEM needs admin'
if (-not (Test-Path $DufsExe)) { throw "dufs.exe not found at $DufsExe (pass -DufsExe)" }
if (-not (Test-Path $ServeDir)) { throw "serve dir not found at $ServeDir (pass -ServeDir)" }

Write-Host '== 1/3 stop session-bound dufs instances + retire ONLOGON tasks ==' -ForegroundColor Cyan
Get-Process dufs -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  stopping pid $($_.Id)"; Stop-Process -Id $_.Id -Force }
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskName -match 'dufs' -and $_.TaskName -ne 'dufs-sccache-l2'
} | ForEach-Object {
    Write-Host "  unregistering old task $($_.TaskName)"
    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
}

Write-Host '== 2/3 register ONSTART/SYSTEM task dufs-sccache-l2 ==' -ForegroundColor Cyan
$action = New-ScheduledTaskAction -Execute $DufsExe -Argument "`"$ServeDir`" --bind 0.0.0.0 --port $Port --allow-all"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'dufs-sccache-l2' -Action $action -Trigger $trigger `
    -Settings $settings -Principal $taskPrincipal -Force | Out-Null
Start-ScheduledTask -TaskName 'dufs-sccache-l2'

Write-Host '== 3/3 verify ==' -ForegroundColor Cyan
Start-Sleep -Seconds 3
$resp = $null
try { $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 10 } catch { $resp = $null }
if ($resp -and $resp.StatusCode -eq 200) {
    Write-Host "dufs-sccache-l2 answers on port $Port (session-independent, restart-on-failure)." -ForegroundColor Green
} else {
    Write-Host 'dufs did NOT answer within 10 s - check: Get-ScheduledTaskInfo dufs-sccache-l2' -ForegroundColor Red
}
if (-not $NoPrompt) { Read-Host 'Press ENTER to close' }
