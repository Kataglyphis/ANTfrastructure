# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force

$versionsFile = Join-Path $env:TEMP_DIR 'versions.env'
if (-not (Test-Path $versionsFile)) {
    Write-Host 'versions.env not found -- skipping'
    return
}

Write-Host "Loading versions from: $versionsFile"
$versions = ConvertFrom-VersionsEnv -Path $versionsFile
foreach ($name in $versions.Keys) {
    $value = $versions[$name]
    [Environment]::SetEnvironmentVariable($name, $value, 'Machine')
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    Write-Host "  $name = $value"
}
Write-Host 'versions.env loaded'
