#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Verify + apply the full Windows Defender exclusion set for Windows-container
# builds. MUST run elevated (Get-MpPreference/Add-MpPreference need admin).
# Prints BEFORE, applies missing, prints AFTER.
#
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\GitHub\ANTfrastructure\windows\scripts\host\Sync-DefenderExclusions.ps1'

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Assert-Elevated

$desiredPaths = @(
    'C:\ProgramData\containerd',
    'C:\ProgramData\buildkitd',
    'C:\ProgramData\Docker',
    'C:\ProgramData\nerdctl',
    'C:\ProgramData\Microsoft\Windows\Containers',
    'C:\temp',
    'C:\WINDOWS\SystemTemp'
)
$desiredProcs = @('buildkitd.exe', 'containerd.exe', 'dockerd.exe', 'nerdctl.exe', 'CExecSvc.exe', 'vmcompute.exe')

# BEFORE and AFTER print the SAME two lists on purpose -- the operator diffs
# them. One owner is what keeps them printable as a diff.
function Show-Exclusions {
    param([Parameter(Mandatory)][string]$Label)

    Write-Host ''
    Write-Host "== $Label ==" -ForegroundColor Cyan
    $pref = Get-MpPreference
    Write-Host '  ExclusionPath:'
    $pref.ExclusionPath | Sort-Object | ForEach-Object { Write-Host ('    ' + $_) }
    Write-Host '  ExclusionProcess:'
    $pref.ExclusionProcess | Sort-Object | ForEach-Object { Write-Host ('    ' + $_) }
    return $pref
}

$mp = Show-Exclusions 'BEFORE'

Write-Host ''
Write-Host '== Applying missing ==' -ForegroundColor Cyan
$missPath = @($desiredPaths | Where-Object { $mp.ExclusionPath -notcontains $_ })
$missProc = @($desiredProcs | Where-Object { $mp.ExclusionProcess -notcontains $_ })
foreach ($p in $missPath) { Add-MpPreference -ExclusionPath $p; Write-Host "  added path $p" -ForegroundColor Green }
foreach ($p in $missProc) { Add-MpPreference -ExclusionProcess $p; Write-Host "  added proc $p" -ForegroundColor Green }
if ($missPath.Count -eq 0 -and $missProc.Count -eq 0) { Write-Host '  nothing missing - all exclusions already present' -ForegroundColor Green }

$null = Show-Exclusions 'AFTER'
Write-Host ''
Write-Host 'Done. Tell the agent to re-run the probe.' -ForegroundColor Green
Read-Host 'Press ENTER to close'
