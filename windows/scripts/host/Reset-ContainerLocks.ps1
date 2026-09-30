#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Elevated, with nothing building: releases the stale handles behind ActivateLayer 0x20 on a fresh base-layer commit.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
# Inline, no module: a repair tool must not depend on an import that may be broken when it is needed.
$bt = @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'C:\Program Files\Stevedore\bin\buildctl.exe', 'D:\Stevedore\bin\buildctl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($bt) {
    & $bt --addr npipe:////./pipe/buildkitd debug workers 2>&1 | Select-String -Pattern 'windows/amd64|worker' | ForEach-Object { $_.Line } | Write-Host
} else {
    Write-Host 'buildctl.exe not found on the usual paths' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Done. Tell the agent to relaunch the build.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
