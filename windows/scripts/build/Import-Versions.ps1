# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# No -Force: this runs from module scope; see docs/windows-build-invariants.md § `Import-Module -Force` only at entry-script top level.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedModulePath }

# TEMP_DIR is baked container ENV and may be unset on a host shell.
if ([string]::IsNullOrWhiteSpace($env:TEMP_DIR)) {
    Write-Host 'TEMP_DIR not set -- skipping versions.env load'
    return
}
$versionsFile = Join-Path $env:TEMP_DIR 'versions.env'
if (-not (Test-Path $versionsFile)) {
    Write-Host 'versions.env not found -- skipping'
    return
}

# Build-args beat the possibly stale file; see docs/windows-builds.md § Import-Versions.ps1.
Write-Host "Loading versions from: $versionsFile"
$versions = ConvertFrom-VersionsEnv -Path $versionsFile
# Every process inherits the baked Machine env, so only a process value that differs from Machine is an override.
$kept = 0
foreach ($name in $versions.Keys) {
    $value = $versions[$name]
    $fromProcess = [Environment]::GetEnvironmentVariable($name, 'Process')
    $fromMachine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    $isExplicitOverride = (-not [string]::IsNullOrWhiteSpace($fromProcess)) -and ($fromProcess -ne $fromMachine)
    if ($isExplicitOverride) {
        # Baked too: the base's ARG-mirrored keys reach Machine only through this branch.
        [Environment]::SetEnvironmentVariable($name, $fromProcess, 'Machine')
        if ($fromProcess -ne $value) {
            Write-Host "  $name = $fromProcess  (kept + baked: build-arg/ENV beats the file's '$value')"
        }
        $kept++
        continue
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Machine')
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    Write-Host "  $name = $value"
}
Write-Host "versions.env loaded ($kept key(s) explicitly overridden by build-arg/ENV and left untouched)"

