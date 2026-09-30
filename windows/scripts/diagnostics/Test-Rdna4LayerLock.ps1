#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# A/B of an enabled RDNA4 dGPU breaking RUN-layer finalize (docker/for-win#14977); GONE retires the toggle workflow.

[CmdletBinding()]
param(
    # Exact device name; empty = every RDNA4 hazard SKU WindowsBuildDriver.Common knows.
    [string]$GpuName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1')

Assert-Elevated -Reason 'Enable/Disable-PnpDevice needs admin'

$probeScript = Join-Path $repoRoot 'windows\scripts\diagnostics\Test-BuildCopy.ps1'
if (-not (Test-Path $probeScript)) { throw "probe script missing: $probeScript" }

function Test-FinalizeState {
    # One GPU-state side of the A/B = one full probe run (tiny + heavy).
    param([string]$Label)
    Write-Host ''
    Write-Host "=== probe [$Label] (Test-BuildCopy.ps1 -Heavy) ===" -ForegroundColor Cyan
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $probeScript -Heavy
    $green = ($LASTEXITCODE -eq 0)
    Write-Host ("probe[{0}]: {1}" -f $Label, $(if ($green) { 'GREEN' } else { 'RED' })) -ForegroundColor $(if ($green) { 'Green' } else { 'Red' })
    return $green
}

if ([string]::IsNullOrWhiteSpace($GpuName)) {
    $gpu = Get-Rdna4HazardDevice | Select-Object -First 1
    if (-not $gpu) { throw 'No RDNA4 hazard device found in Device Manager - nothing to test (pass -GpuName for a non-standard SKU name).' }
} else {
    $gpu = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $GpuName } | Select-Object -First 1
    if (-not $gpu) { throw "'$GpuName' not found in Device Manager." }
}
Write-Host ("GPU: {0} [{1}]" -f $gpu.FriendlyName, $gpu.Status) -ForegroundColor Cyan

if ($gpu.Status -ne 'OK') {
    Write-Host 'dGPU is already DISABLED - testing the off-state only (enable it first for the full A/B).' -ForegroundColor Yellow
    if (Test-FinalizeState -Label 'off') {
        Write-Host 'dGPU-off state is finalize-green (as expected). Re-run with the dGPU enabled for the A/B verdict.' -ForegroundColor Green
        exit 0
    }
    Write-Host 'RED with the dGPU already off - the host has a problem beyond the RDNA4 interaction.' -ForegroundColor Red
    exit 1
}

if (Test-FinalizeState -Label 'on') {
    Write-Host ''
    Write-Host 'VERDICT: INTERACTION GONE - RUN-layer finalize is green with the dGPU ENABLED (tiny + heavy).' -ForegroundColor Green
    Write-Host 'If this repeats across a real chain build, retire the toggle workflow + Assert-NoActiveRdna4Gpu gate (AGENTS.md).' -ForegroundColor Green
    exit 0
}

Write-Host 'RED with the dGPU enabled - running the off-side of the A/B...' -ForegroundColor Yellow
$disabled = $false
# Initialized up front, so the verdict line never reads a try-only value under StrictMode.
$offGreen = $false
try {
    # Set when the disable is issued: it completes asynchronously, and re-enabling an OK device is a no-op.
    $disabled = $true
    $off = Set-Rdna4DeviceState -Device $gpu -State Disabled
    if (-not $off.Ok) { throw "failed to disable '$($gpu.FriendlyName)' (status '$($off.Status)') - cannot run the off-side (re-enable attempted in finally)" }
    Write-Host 'dGPU DISABLED (display falls back to the iGPU)' -ForegroundColor Cyan
    $offGreen = Test-FinalizeState -Label 'off'
} finally {
    if ($disabled) {
        # Verified, since a swallowed re-enable failure would strand the host on the iGPU.
        $on = Set-Rdna4DeviceState -Device $gpu -State Enabled
        if ($on.Ok) {
            Write-Host 'dGPU RE-ENABLED (verified)' -ForegroundColor Cyan
        } else {
            Write-Host ("dGPU RE-ENABLE FAILED - status is '{0}'. Re-enable manually: Set-Rdna4Gpu.ps1 (elevated, default action)." -f $on.Status) -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($offGreen) {
    Write-Host 'VERDICT: INTERACTION PRESENT - dGPU on = red, dGPU off = green. Build inside the toggle window:' -ForegroundColor Yellow
    Write-Host '  elevated Set-Rdna4Gpu.ps1 -Disable -> build -> re-enable (Assert-NoActiveRdna4Gpu enforces this).' -ForegroundColor Yellow
    exit 2
}
Write-Host 'VERDICT: INCONCLUSIVE - red in BOTH GPU states; something beyond the RDNA4 interaction is broken (see AGENTS.md Common Failure Modes).' -ForegroundColor Red
exit 1
