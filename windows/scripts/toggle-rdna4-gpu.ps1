# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Enable/disable the AMD Radeon RX 9070 XT (RDNA4) in Device Manager.
# RE-INSTATED as the build-window workaround 2026-08-10 (the 2026-08-09
# "obsolete" verdict is SUPERSEDED): a same-boot A/B proved an ENABLED RDNA4
# dGPU makes every process-isolated RUN-layer finalize fail with
# hcsshim::ActivateLayer 0x20 (upstream docker/for-win#14977; severity shifts
# with the Windows patch level - post-KB5101684 even 10-byte RUN layers trip).
# Workflow: -Disable, build the chain (display falls back to the iGPU),
# re-enable (default action). build-buildkit.ps1's Assert-NoActiveRdna4Gpu
# preflight refuses to start while the dGPU is enabled.
# Leaves the RDNA2 iGPU alone (it is not implicated). ELEVATED.
#
#   pwsh -File windows\scripts\toggle-rdna4-gpu.ps1            # default: enable
#   pwsh -File windows\scripts\toggle-rdna4-gpu.ps1 -Disable
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\toggle-rdna4-gpu.ps1'

#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$Disable,
    # Other RDNA4 SKUs (RX 9060 XT, AI PRO R9700, ...) hit the same layer-lock
    # and the same gate refusal - without this parameter the prescribed remedy
    # script could not act on them at all (backlog #1/#6, review 2026-08-10).
    [string]$GpuName = 'AMD Radeon RX 9070 XT'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (Enable/Disable-PnpDevice needs admin).'
}

$target = Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -eq $GpuName }
if (-not $target) {
    Write-Host "'$GpuName' not found (renamed/removed?) - listing Radeons:" -ForegroundColor Yellow
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
