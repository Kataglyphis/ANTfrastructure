#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Make the dufs WebDAV endpoint (sccache L2) SESSION-INDEPENDENT (attribution
# dossier 2.8, 2026-08-11): today dufs runs as an ONLOGON scheduled task bound
# to the RDP session - alive when the driver's endpoint gate checks, killable
# by a mid-run logoff/lock, after which every multilevel WebDAV write fails
# OPEN (policy l0: logged only) with an empty L2 as the only symptom. Two
# instances were live on 2026-08-10 (one per logon event).
# This script (ELEVATED):
#   1. stops every running dufs.exe and disables/removes ONLOGON dufs tasks;
#   2. registers ONE 'dufs-sccache-l2' scheduled task: ONSTART, SYSTEM,
#      restart-on-failure - independent of any user session;
#   3. starts it and verifies the endpoint answers.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\host\setup-dufs-service.ps1'

[CmdletBinding()]
param(
    [string]$DufsExe = "$env:USERPROFILE\scoop\shims\dufs.exe",
    [string]$ServeDir = "$env:USERPROFILE\sccache-cache",
    [int]$Port = 5000,
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (schtasks /RU SYSTEM needs admin).'
}
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
