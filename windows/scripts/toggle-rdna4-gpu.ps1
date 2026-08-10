# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Enable/disable the AMD Radeon RX 9070 XT (RDNA4) in Device Manager.
# OBSOLETE as a fix since 2026-08-09: the build-COPY (ActivateLayer 0x20)
# failure it targeted was a FAULTY AMD ADRENALINE installation, cured by
# reinstall, not by GPU-disable. Kept for historical diagnostics; harmless.
# Leaves the RDNA2 iGPU alone (it is not implicated). ELEVATED.
#
#   pwsh -File windows\scripts\toggle-rdna4-gpu.ps1            # default: enable
#   pwsh -File windows\scripts\toggle-rdna4-gpu.ps1 -Disable
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\toggle-rdna4-gpu.ps1'

#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Disable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (Enable/Disable-PnpDevice needs admin).'
}

$target = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -eq 'AMD Radeon RX 9070 XT' }
if (-not $target) {
    Write-Host 'RX 9070 XT not found (renamed/removed?) - listing Radeons:' -ForegroundColor Yellow
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Radeon' } |
        Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize | Out-Host
    Read-Host 'Press ENTER to close'; exit 1
}

foreach ($d in @($target)) {
    Write-Host ("BEFORE: {0}  [{1}]" -f $d.FriendlyName, $d.Status) -ForegroundColor Cyan
    if ($Disable) {
        if ($d.Status -ne 'OK') { Write-Host '  already not OK.' }
        else { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; Write-Host ('  disabled ' + $d.InstanceId) -ForegroundColor Green }
    } else {
        $d.Refresh()
        if ($d.Status -eq 'OK') { Write-Host '  already OK.' -ForegroundColor Green }
        else { Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; Write-Host ('  enabled ' + $d.InstanceId) -ForegroundColor Green }
    }
}
Start-Sleep -Seconds 2
Write-Host ''
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Radeon' } |
    Select-Object Status, FriendlyName | Format-Table -AutoSize | Out-Host
Write-Host 'Done.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
