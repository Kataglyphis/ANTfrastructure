#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# The BUNDLED elevated between-runs window (backlog close-out 2026-08-11):
# one UAC click executes, in order —
#   1. restore the buildkitd service env (BUILDKIT_STEP_LOG_MAX_SIZE/-SPEED=-1)
#      — the 0a gate refuses chain launches until this is done;
#   2. deploy the new GC budgets (windows/buildkitd.toml, item 34: 400/450GB)
#      via apply-buildkitd-gcpolicy.ps1 (which restarts buildkitd — its own
#      guard refuses while a build is running);
#   3. release the 2026-08-10/11 diagnostic image tags (incl. the POISONED
#      probe-build-copy chain left by the rewrite-timestamp exporter crash);
#   4. print the verify steps (probe smoke; reboot only if the probe is
#      still red afterwards).
# NEVER run while a chain build is solving.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\Kataglyphis-ContainerHub\windows\scripts\host\apply-elevated-window.ps1'

[CmdletBinding()]
param([switch]$NoPrompt)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1')

Assert-Elevated -Reason 'service env + Restart-Service + nerdctl need admin'

Write-Host '== 1/4 buildkitd service env (BUILDKIT_STEP_LOG_MAX_SIZE/-SPEED=-1) ==' -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -Name Environment `
    -PropertyType MultiString -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1', 'BUILDKIT_STEP_LOG_MAX_SPEED=-1') -Force | Out-Null
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd').Environment | ForEach-Object { Write-Host "  $_" }

Write-Host '== 2/4 GC budgets (item 34) via apply-buildkitd-gcpolicy.ps1 (restarts buildkitd) ==' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'apply-buildkitd-gcpolicy.ps1')

Write-Host '== 3/4 release diagnostic image tags (incl. the poisoned probe chain) ==' -ForegroundColor Cyan
$nerdctl = Get-PreferredToolPath -CommandName 'nerdctl.exe' -CandidatePaths @("$env:ProgramFiles\Stevedore\bin\nerdctl.exe", 'D:\Stevedore\bin\nerdctl.exe')
if ($nerdctl) {
    $tagPatterns = 'copyprobe-', 'sweep-', 'rdna4ab-', 'flush-', 'mlchain-probe', 'verify-cuda-cache',
    'postboot-', 'nano-', 'gpuab-', 'diag-', 'probe-build-copy'
    $images = @(& $nerdctl --namespace buildkit images --format '{{.Repository}}:{{.Tag}}' 2>$null)
    $victims = @($images | Where-Object { $img = $_; ($tagPatterns | Where-Object { $img -match [regex]::Escape($_) }).Count -gt 0 } | Sort-Object -Unique)
    if ($victims) {
        $victims | ForEach-Object { Write-Host "  rmi $_"; & $nerdctl --namespace buildkit rmi $_ 2>&1 | Select-Object -Last 1 }
    } else { Write-Host '  (no matching diagnostic tags found)' }
} else {
    Write-Warning 'nerdctl not found - release the diag tags manually (docs § Store GC).'
}

Write-Host '== 4/4 verify ==' -ForegroundColor Cyan
Write-Host '  Next: pwsh -File windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy   (non-admin shell)'
Write-Host '  If the probe is STILL red after this cleanup, the poisoned snapshot survived the'
Write-Host '  tag release - reboot the host (documented worst case), then re-run the probe.'
Write-Host '  Chain relaunches no longer need -SkipStepLogGate from here on.'
Write-Host 'ELEVATED WINDOW COMPLETE.' -ForegroundColor Green
if (-not $NoPrompt) { Read-Host 'Press ENTER to close' }
