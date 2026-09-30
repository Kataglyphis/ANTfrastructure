#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Admin, never while a build solves (the restart kills them): deploys buildkitd.toml and points the service at it.

[CmdletBinding()]
param(
    [string]$ConfigDest = 'C:\ProgramData\buildkitd\buildkitd.toml',
    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Assert-Elevated -Reason 'service re-registration needs it'
$src = Join-Path (Split-Path $scriptAssetRoot -Parent) 'buildkitd.toml'
if (-not (Test-Path $src)) { throw "repo config not found: $src" }

if (-not $Force) {
    $live = @(Get-Process buildctl -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0) {
        throw ("{0} live buildctl process(es) found (pids: {1}) — a service restart kills their solves. " -f $live.Count, (($live | ForEach-Object Id) -join ', ')) +
            'Wait for the build to finish, or pass -Force if they are stale.'
    }
}

$svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -ErrorAction Stop
$binPath = $svc.ImagePath
Write-Host "current ImagePath: $binPath"

New-Item -ItemType Directory -Force -Path (Split-Path $ConfigDest -Parent) | Out-Null
Copy-Item $src $ConfigDest -Force
Write-Host "deployed $src -> $ConfigDest"

if ($binPath -notmatch '--config') {
    # --config goes right after the exe path; every existing flag, --debug included, stays.
    if ($binPath -match '^(?<exe>"[^"]+"|\S+)\s*(?<rest>.*)$') {
        $newBin = '{0} --config {1} {2}' -f $Matches['exe'], $ConfigDest, $Matches['rest']
    } else {
        throw "cannot parse ImagePath: $binPath"
    }
    Write-Host "re-registering: $newBin"
    & sc.exe config buildkitd binPath= $newBin | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed (exit $LASTEXITCODE)" }
} else {
    Write-Host '--config already present in ImagePath; config file replaced in place.'
}

# Without -Force, Restart-Service refuses while dependent services hang off buildkitd.
Restart-Service buildkitd -Force
Write-Host 'buildkitd restarted.' -ForegroundColor Green

# The effective GC rules must show reservedSpace, not the computed defaults that once evicted the VS layer.
$buildctl = @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($buildctl) {
    & $buildctl debug workers -v 2>&1 | Select-String -Pattern 'GC Policy|reserved|maxUsedSpace|minFreeSpace|keepDuration|all=|filters' | ForEach-Object { $_.Line } | Write-Host
} else {
    Write-Host 'buildctl not found for verification — run: buildctl debug workers -v' -ForegroundColor Yellow
}
