#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# One UAC click for the between-runs admin steps (step-log env, GC budgets, diag tag release); never while a chain solves.

[CmdletBinding()]
param([switch]$NoPrompt)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1')

Assert-Elevated -Reason 'service env + Restart-Service + nerdctl need admin'

Write-Host '== 1/4 buildkitd service env (BUILDKIT_STEP_LOG_MAX_SIZE/-SPEED=-1) ==' -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment `
    -PropertyType MultiString -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1', 'BUILDKIT_STEP_LOG_MAX_SPEED=-1') -Force | Out-Null
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd').Environment | ForEach-Object { Write-Host "  $_" }

Write-Host '== 2/4 GC budgets (item 34) via Set-BuildkitdGcpolicy.ps1 (restarts buildkitd) ==' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Set-BuildkitdGcpolicy.ps1')

Write-Host '== 3/4 release diagnostic image tags (incl. the poisoned probe chain) ==' -ForegroundColor Cyan
$nerdctl = Get-PreferredToolPath -CommandName 'nerdctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\nerdctl.exe", 'D:\Stevedore\bin\nerdctl.exe')
if ($nerdctl) {
    $tagPatterns = 'copyprobe-', 'sweep-', 'rdna4ab-', 'flush-', 'mlchain-probe', 'verify-cuda-cache',
    'postboot-', 'nano-', 'gpuab-', 'diag-', 'probe-build-copy'
    $images = @(& $nerdctl --namespace buildkit images --format '{{.Repository}}:{{.Tag}}' 2>$null)
    $victims = @($images | Where-Object { $img = $_; @($tagPatterns | Where-Object { $img -match [regex]::Escape($_) }).Count -gt 0 } | Sort-Object -Unique)
    if ($victims) {
        $victims | ForEach-Object { Write-Host "  rmi $_"; & $nerdctl --namespace buildkit rmi $_ 2>&1 | Select-Object -Last 1 }
    } else { Write-Host '  (no matching diagnostic tags found)' }
} else {
    Write-Warning 'nerdctl not found - release the diag tags manually (docs § Store GC).'
}

Write-Host '== 4/4 verify ==' -ForegroundColor Cyan
Write-Host '  Next: pwsh -File windows\scripts\diagnostics\Test-BuildCopy.ps1 -Heavy   (non-admin shell)'
Write-Host '  If the probe is STILL red after this cleanup, the poisoned snapshot survived the'
Write-Host '  tag release - reboot the host (documented worst case), then re-run the probe.'
Write-Host '  Chain relaunches no longer need -SkipStepLogGate from here on.'
Write-Host 'ELEVATED WINDOW COMPLETE.' -ForegroundColor Green
if (-not $NoPrompt) { Read-Host 'Press ENTER to close' }
