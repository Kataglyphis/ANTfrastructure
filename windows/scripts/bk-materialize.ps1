# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# MATERIALIZE-solve payload for the BuildKit lane: restores a warm solve's
# handoff (Import-BuildHandoff) inside a calm, seconds-long container whose
# snapshot finalizes normally — the exported image carries the artifacts.
# Counterpart of bk-warm.ps1; keeps the Dockerfile RUNs one-liners.

#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    # Scrub package-manager/temp scratch before the layer closes (used by the
    # LAST materialize of a chain — cache junk is dead weight in the image).
    [switch]$Scrub
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
Import-BuildHandoff -Name $Name
if ($Scrub) { Clear-BuildScratch }

exit 0
