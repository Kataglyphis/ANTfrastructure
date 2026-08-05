# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# GUARDED, without -Force (ROOT FIX 2026-08-05): this script is `&`-invoked
# FROM MODULE SCOPE by Import-CanonicalVersions, and a forced re-import from
# there unloads the CALLER's top-level Shared and rebinds it into the module's
# private session state — Shared exports (Resolve-DirectoryPath & friends)
# went CommandNotFound at the caller's top level and killed the gstreamer
# merge-warm solve twice. The entry-script case (Dockerfile.base's bake RUN,
# fresh pwsh) still imports normally: nothing is loaded there yet. See
# AGENTS.md invariant "-Force only at ENTRY-script top level".
$sharedModulePath = Join-Path $PSScriptRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedModulePath }

# TEMP_DIR is baked container ENV; on a host shell it may be unset — skip
# instead of letting Join-Path throw under EAP=Stop (found by the 2026-08-05
# root-fix repro).
if ([string]::IsNullOrWhiteSpace($env:TEMP_DIR)) {
    Write-Host 'TEMP_DIR not set -- skipping versions.env load'
    return
}
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

