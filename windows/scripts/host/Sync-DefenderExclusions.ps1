#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# Elevated: applies the Defender exclusions Windows-container builds need, printing the set before and after.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
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

# One printer for BEFORE and AFTER so the operator can diff them.
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
