#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Elevated, with nothing building: releases the stale handles behind ActivateLayer 0x20 on a fresh base-layer commit.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1')

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This must run ELEVATED (service restart + process kill need admin).'
}

Write-Host ''
Write-Host '== Step 1: stale Hyper-V workers (vmwp) from failed solves ==' -ForegroundColor Cyan
$v = Get-Process vmwp -ErrorAction SilentlyContinue
if ($v) {
    $v | Select-Object Id, StartTime | Format-Table -AutoSize
    foreach ($p in $v) { Stop-Process -Id $p.Id -Force; Write-Host "  killed vmwp $($p.Id)" -ForegroundColor Yellow }
    Start-Sleep -Seconds 2
} else {
    Write-Host '  no vmwp to kill'
}

Write-Host ''
Write-Host '== Step 2: restart containerd (stops buildkitd), then start buildkitd ==' -ForegroundColor Cyan
Restart-Service containerd -Force
Start-Sleep -Seconds 4
Start-Service buildkitd
Start-Sleep -Seconds 4
Get-Service containerd, buildkitd | Select-Object Name, Status | Format-Table -AutoSize

Write-Host ''
Write-Host '== Step 3: buildctl reaches the worker? ==' -ForegroundColor Cyan
Write-HostMaintenanceProbe -Command (Get-HostMaintenanceBuildCtlPath -IncludeCProgramFilesFallback) -ArgumentList @('--addr', 'npipe:////./pipe/buildkitd', 'debug', 'workers') `
    -Pattern 'windows/amd64|worker' -UnavailableMessage 'buildctl.exe not found on the usual paths'

Write-Host ''
Write-Host 'Done. Tell the agent to relaunch the build.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
