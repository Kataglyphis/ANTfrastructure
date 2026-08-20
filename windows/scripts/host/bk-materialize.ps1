#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# RETIRED FROM THE DOCKERFILES (de-warming 2026-08-05) — kept as the tested
# rollback path together with bk-warm.ps1; see bk-warm.ps1's header for the
# full story and the canary that gates any return of the pattern.
#
# MATERIALIZE-solve payload for the BuildKit lane: restores a warm solve's
# handoff (Import-BuildHandoff) inside a calm, seconds-long container whose
# snapshot finalizes normally — the exported image carries the artifacts.
# Counterpart of bk-warm.ps1; keeps the Dockerfile RUNs one-liners.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    # Scrub package-manager/temp scratch before the layer closes (used by the
    # LAST materialize of a chain — cache junk is dead weight in the image).
    [switch]$Scrub
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# No -DisableNameChecking: every exported function uses an approved verb (the
# three build-*-all wrappers import this module bare and warn-free).
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1') -Force
Import-BuildHandoff -Name $Name
if ($Scrub) { Clear-BuildScratch }

exit 0
