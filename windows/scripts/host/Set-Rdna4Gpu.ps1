#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Works around docker/for-win#14977: an enabled RDNA4 dGPU fails process-isolated layer finalize; -Disable to build, default re-enables.

[CmdletBinding()]
param(
    [switch]$Disable,
    # Empty matches every RDNA4 hazard SKU from WindowsBuildDriver.Common; a name exact-matches one device.
    [string]$GpuName = '',
    # Skip the Read-Host pauses so automation can call this script.
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsBuildDriver.Common.psm1')

Assert-Elevated -Reason 'Enable/Disable-PnpDevice needs admin'

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
