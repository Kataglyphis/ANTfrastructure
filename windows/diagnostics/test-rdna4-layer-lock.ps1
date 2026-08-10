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
# Sequence (mirrors the 2026-08-10 diagnosis; ~1-3 min, ELEVATED for the GPU
# toggle, needs a running buildkitd):
#   1. tiny RUN-layer finalize probe with the dGPU as-is (usually ENABLED)
#      - green => INTERACTION GONE (nothing else to do)
#   2. disable the dGPU -> tiny probe -> heavy probe (Dockerfile.heavy)
#   3. RE-ENABLE the dGPU (finally-guarded - also on Ctrl+C/throw)
#
# Verdicts: GONE (on-green) / PRESENT (on-red, off-green) / INCONCLUSIVE
# (red in both states - host broken beyond the GPU interaction; check
# probe-build-copy.ps1 -Heavy history and AGENTS.md Common Failure Modes).

#requires -Version 7.0
[CmdletBinding()]
param(
    # Device name to toggle; matches toggle-rdna4-gpu.ps1's target.
    [string]$GpuName = 'AMD Radeon RX 9070 XT'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run ELEVATED (Enable/Disable-PnpDevice needs admin).'
}

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$probeDir = Join-Path $repoRoot 'windows\diagnostics\probe-build-copy'
$buildctl = "$env:ProgramFiles\Stevedore\bin\buildctl.exe"
if (-not (Test-Path $buildctl)) { throw "buildctl not found at $buildctl" }
foreach ($f in 'Dockerfile', 'Dockerfile.heavy', 'hello.txt') {
    if (-not (Test-Path (Join-Path $probeDir $f))) { throw "probe asset missing: $f (expected under $probeDir)" }
}

$stamp = Get-Date -Format 'HHmmss'
function Test-RunLayerFinalize {
    param([ValidateSet('tiny', 'heavy')][string]$Kind, [string]$Label)
    $opts = if ($Kind -eq 'heavy') { @('--opt', 'filename=Dockerfile.heavy') } else { @() }
    & $buildctl --addr npipe:////./pipe/buildkitd build --frontend dockerfile.v0 `
        --local "context=$probeDir" --local "dockerfile=$probeDir" @opts --no-cache `
        --output "type=image,name=docker.io/local/kataglyphis:rdna4ab-$Label-$stamp,unpack=true" 2>&1 |
        Select-Object -Last 2 | ForEach-Object { Write-Host "  $_" }
    $green = ($LASTEXITCODE -eq 0)
    Write-Host ("probe[{0}/{1}]: {2}" -f $Kind, $Label, $(if ($green) { 'GREEN' } else { 'RED' })) -ForegroundColor $(if ($green) { 'Green' } else { 'Red' })
    return $green
}

$gpu = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $GpuName } | Select-Object -First 1
if (-not $gpu) { throw "'$GpuName' not found in Device Manager - pass -GpuName, or this host has no RDNA4 dGPU (nothing to test)." }
Write-Host ("GPU: {0} [{1}]" -f $gpu.FriendlyName, $gpu.Status) -ForegroundColor Cyan

if ($gpu.Status -ne 'OK') {
    Write-Host 'dGPU is already DISABLED - testing the off-state only (enable it first for the full A/B).' -ForegroundColor Yellow
    $offTiny = Test-RunLayerFinalize -Kind tiny -Label off-tiny
    $offHeavy = Test-RunLayerFinalize -Kind heavy -Label off-heavy
    if ($offTiny -and $offHeavy) { Write-Host 'dGPU-off state is finalize-green (as expected). Re-run with the dGPU enabled for the A/B verdict.' -ForegroundColor Green; exit 0 }
    Write-Host 'RED with the dGPU already off - the host has a problem beyond the RDNA4 interaction.' -ForegroundColor Red; exit 1
}

$onGreen = Test-RunLayerFinalize -Kind tiny -Label on-tiny
if ($onGreen) {
    $onHeavy = Test-RunLayerFinalize -Kind heavy -Label on-heavy
    if ($onHeavy) {
        Write-Host ''
        Write-Host 'VERDICT: INTERACTION GONE - RUN-layer finalize is green with the dGPU ENABLED (tiny + heavy).' -ForegroundColor Green
        Write-Host 'If this repeats across a real chain build, retire the toggle workflow + Assert-NoActiveRdna4Gpu gate (AGENTS.md).' -ForegroundColor Green
        exit 0
    }
}

Write-Host 'RED with the dGPU enabled - running the off-side of the A/B...' -ForegroundColor Yellow
$disabled = $false
try {
    Disable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false
    $disabled = $true
    Write-Host 'dGPU DISABLED (display falls back to the iGPU)' -ForegroundColor Cyan
    Start-Sleep -Seconds 3
    $offTiny = Test-RunLayerFinalize -Kind tiny -Label off-tiny
    $offHeavy = if ($offTiny) { Test-RunLayerFinalize -Kind heavy -Label off-heavy } else { $false }
} finally {
    if ($disabled) {
        Enable-PnpDevice -InstanceId $gpu.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host 'dGPU RE-ENABLED' -ForegroundColor Cyan
    }
}

Write-Host ''
if ($offTiny -and $offHeavy) {
    Write-Host 'VERDICT: INTERACTION PRESENT - dGPU on = red, dGPU off = green. Build inside the toggle window:' -ForegroundColor Yellow
    Write-Host '  elevated toggle-rdna4-gpu.ps1 -Disable -> build -> re-enable (Assert-NoActiveRdna4Gpu enforces this).' -ForegroundColor Yellow
    exit 2
}
Write-Host 'VERDICT: INCONCLUSIVE - red in BOTH GPU states; something beyond the RDNA4 interaction is broken (see AGENTS.md Common Failure Modes).' -ForegroundColor Red
exit 1
