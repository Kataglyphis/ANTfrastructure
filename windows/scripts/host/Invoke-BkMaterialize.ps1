#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Retired MATERIALIZE payload, kept as the rollback path: see docs/windows-build-lanes.md § Restoring the warm/materialize rollback

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    # Scrub package-manager and temp scratch before the layer closes; for a chain's last materialize.
    [switch]$Scrub
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1') -Force
Import-BuildHandoff -Name $Name
if ($Scrub) { Clear-BuildScratch }

exit 0
