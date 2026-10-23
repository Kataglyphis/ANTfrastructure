#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Elevated, 10-40 min, with nothing building: DISM /RestoreHealth then sfc, for a host whose DISM COM API is broken.

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsHostMaintenance.Common.psm1')

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'MUST run elevated' -ForegroundColor Red; Read-Host 'Enter'; exit 1
}


Write-HostMaintenanceMessage '== 1. DISM /Online /Cleanup-Image /RestoreHealth (repairs the component store) ==' 'Cyan'
Write-HostMaintenanceMessage '    This needs internet and can take 10-40 minutes. Do not close the window.' 'Yellow'
dism.exe /Online /Cleanup-Image /RestoreHealth
Write-HostMaintenanceMessage ("    dism exit: " + $LASTEXITCODE)

Write-HostMaintenanceMessage '== 2. sfc /scannow ==' 'Cyan'
sfc.exe /scannow
Write-HostMaintenanceMessage ("    sfc exit: " + $LASTEXITCODE)

Write-HostMaintenanceMessage '== 3. re-test DISM API (was: Klasse nicht registriert) ==' 'Cyan'
try {
    $f = Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object { $_.FeatureName -match 'Container|Hyper|VirtualMachine|ProjFS' }
    $f | Sort-Object FeatureName | ForEach-Object { Write-Host ('  ' + $_.FeatureName + ' = ' + $_.State) }
    Write-HostMaintenanceMessage 'DISM API now WORKS.' 'Green'
} catch {
    Write-HostMaintenanceMessage ('DISM API STILL broken: ' + $_.Exception.Message) 'Red'
    Write-HostMaintenanceMessage 'If RestoreHealth could not reach Windows Update, retry with /Source <path-to>install.wim: /RestoreHealth /Source D:\sources\install.wim /LimitAccess'
}

Write-HostMaintenanceMessage '== 4. committed build probe (image export, -Heavy) ==' 'Cyan'
# Absolute path: an elevated Start-Process runs in System32. The probe exports type=image; type=local fails even on a healthy host.
$probeScript = Join-Path $scriptAssetRoot 'diagnostics\Test-BuildCopy.ps1'
& pwsh -NoProfile -File $probeScript -Heavy 2>&1 | Select-Object -Last 12 | ForEach-Object { Write-Host $_ }
Write-HostMaintenanceMessage ('probe exit: ' + $LASTEXITCODE)

Write-Host ''
Write-Host 'Done - report the probe result to the agent.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
