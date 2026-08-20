#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# RDNA4 layer-lock A/B: is the "enabled AMD RDNA4 dGPU kills process-isolated
# RUN-layer finalize" interaction (hcsshim::ActivateLayer 0x20, upstream
# docker/for-win#14977; A/B-proven on the RX 9070 XT host 2026-08-10) still
# present on this host? Re-run after every Adrenalin/Windows update - the
# severity moved with the Windows patch level before (post-KB5101684 even
# 10-byte RUN layers tripped), and the day upstream fixes it this script's
# GONE verdict is the signal to retire the toggle workflow and the
# Assert-NoActiveRdna4Gpu preflight gate.
#
# The finalize verdict per GPU state is DELEGATED to probe-build-copy.ps1
# -Heavy (backlog #5): the probe owns digest-pinned bases, lane logging and
# the output-shape/quoting lessons - this script only orchestrates the GPU
# state around two probe runs. Per-lane logs land in out\build-logs\ (the
# probe prints each path).
#
# Sequence (~2-4 min, ELEVATED for the GPU toggle, needs a running buildkitd):
#   1. probe with the dGPU as-is (usually ENABLED) - green => INTERACTION GONE
#   2. disable the dGPU -> probe again
#   3. RE-ENABLE the dGPU (finally-guarded - also on Ctrl+C/throw)
#
# Verdicts: GONE (on-green) / PRESENT (on-red, off-green) / INCONCLUSIVE
# (red in both states - host broken beyond the GPU interaction; check
# probe-build-copy.ps1 -Heavy history and AGENTS.md Common Failure Modes).

[CmdletBinding()]
param(
    # Exact device name override; empty = resolve every RDNA4 hazard SKU via
    # the single-source pattern in WindowsBuildDriver.Common (backlog #1).
    [string]$GpuName = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repoRoot 'windows\scripts\modules\WindowsBuildDriver.Common.psm1')

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (Enable/Disable-PnpDevice needs admin).'
}

$probeScript = Join-Path $repoRoot 'windows\scripts\diagnostics\probe-build-copy.ps1'
if (-not (Test-Path $probeScript)) { throw "probe script missing: $probeScript" }

function Test-FinalizeState {
    # One GPU-state side of the A/B = one full probe run (tiny + heavy).
    param([string]$Label)
    Write-Host ''
    Write-Host "=== probe [$Label] (probe-build-copy.ps1 -Heavy) ===" -ForegroundColor Cyan
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
# Initialized up front: under StrictMode a value assigned only inside try is
# one refactor away from a StrictMode error in the verdict line (backlog #25).
$offGreen = $false
try {
    # $disabled is set the moment the disable is ISSUED, not after the
    # verification (review find #4): Disable-PnpDevice completes
    # asynchronously, so a slow driver teardown can fail the 2 s post-state
    # check while the device still goes down moments later - the finally
    # must then attempt the re-enable anyway (re-enabling an already-OK
    # device is a no-op).
    $disabled = $true
    $off = Set-Rdna4DeviceState -Device $gpu -State Disabled
    if (-not $off.Ok) { throw "failed to disable '$($gpu.FriendlyName)' (status '$($off.Status)') - cannot run the off-side (re-enable attempted in finally)" }
    Write-Host 'dGPU DISABLED (display falls back to the iGPU)' -ForegroundColor Cyan
    $offGreen = Test-FinalizeState -Label 'off'
} finally {
    if ($disabled) {
        # Post-state-verified shared primitive (backlog #6): a swallowed
        # re-enable failure strands the host on the iGPU while the console
        # claims otherwise.
        $on = Set-Rdna4DeviceState -Device $gpu -State Enabled
        if ($on.Ok) {
            Write-Host 'dGPU RE-ENABLED (verified)' -ForegroundColor Cyan
        } else {
            Write-Host ("dGPU RE-ENABLE FAILED - status is '{0}'. Re-enable manually: toggle-rdna4-gpu.ps1 (elevated, default action)." -f $on.Status) -ForegroundColor Red
        }
    }
}

Write-Host ''
if ($offGreen) {
    Write-Host 'VERDICT: INTERACTION PRESENT - dGPU on = red, dGPU off = green. Build inside the toggle window:' -ForegroundColor Yellow
    Write-Host '  elevated toggle-rdna4-gpu.ps1 -Disable -> build -> re-enable (Assert-NoActiveRdna4Gpu enforces this).' -ForegroundColor Yellow
    exit 2
}
Write-Host 'VERDICT: INCONCLUSIVE - red in BOTH GPU states; something beyond the RDNA4 interaction is broken (see AGENTS.md Common Failure Modes).' -ForegroundColor Red
exit 1
