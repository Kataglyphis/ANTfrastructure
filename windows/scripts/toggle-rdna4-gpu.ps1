# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Enable/disable the RDNA4 dGPU (default: every hazard-set match, e.g.
# RX 9070 XT / RX 9060 / AI PRO R9700) in Device Manager.
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
    # Empty default = resolve ALL RDNA4 hazard SKUs via the single-source
    # pattern in WindowsBuildDriver.Common (backlog #1: the hardcoded
    # 'RX 9070 XT' literal was one of three divergent hazard-set copies -
    # on an RX 9060 host this script could not act at all). An explicit
    # -GpuName still exact-matches one device.
    [string]$GpuName = '',
    # Suppress the interactive Read-Host pauses so the A/B diagnostic (and
    # any other automation) can call this script (backlog #6).
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules\WindowsBuildDriver.Common.psm1')

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (Enable/Disable-PnpDevice needs admin).'
}

if ([string]::IsNullOrWhiteSpace($GpuName)) {
    $target = Get-Rdna4HazardDevice
} else {
    $target = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq $GpuName }
}
if (-not $target) {
    $wanted = if ($GpuName) { "'$GpuName'" } else { 'no RDNA4 hazard device' }
    Write-Host "$wanted found (renamed/removed?) - listing Radeons:" -ForegroundColor Yellow
    Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Radeon' } |
        Select-Object Status, FriendlyName, InstanceId | Format-Table -AutoSize | Out-Host
    if (-not $NoPrompt) { Read-Host 'Press ENTER to close' }
    exit 1
}

$targetState = if ($Disable) { 'Disabled' } else { 'Enabled' }
$failed = $false
foreach ($d in @($target)) {
    Write-Host ("BEFORE: {0}  [{1}]" -f $d.FriendlyName, $d.Status) -ForegroundColor Cyan
    if ((-not $Disable) -and $d.Status -eq 'OK') { Write-Host '  already OK.' -ForegroundColor Green; continue }
    if ($Disable -and $d.Status -ne 'OK') { Write-Host '  already not OK.'; continue }
    # Shared, post-state-verified primitive (backlog #6).
    $result = Set-Rdna4DeviceState -Device $d -State $targetState
    if ($result.Ok) {
        Write-Host ("  {0} {1}" -f $targetState.ToLower(), $d.InstanceId) -ForegroundColor Green
    } else {
        Write-Host ("  FAILED to reach state '{0}' - status is '{1}' ({2})" -f $targetState, $result.Status, $d.InstanceId) -ForegroundColor Red
        $failed = $true
    }
}
Write-Host ''
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Radeon' } |
    Select-Object Status, FriendlyName | Format-Table -AutoSize | Out-Host
if ($failed) {
    Write-Host 'Done WITH FAILURES (see above).' -ForegroundColor Red
} else {
    Write-Host 'Done.' -ForegroundColor Green
}
if (-not $NoPrompt) { Read-Host 'Press ENTER to close' }
if ($failed) { exit 1 }
