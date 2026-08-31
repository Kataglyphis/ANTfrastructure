#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# RETIRED FROM THE DOCKERFILES (de-warming 2026-08-06, round 2): the
# ExportLayer-0x3 defect this pattern routed around was root-caused to the
# runhcs shim's hardcoded 30s tearDownTimeout (real heavy-churn teardown:
# ~117s measured) and is fixed by the patched shim in Stevedore\bin — all
# solves are direct now. KEPT (with bk-materialize.ps1 + the handoff helpers
# + their tests) as the rollback path: if the canary
# (docs/windows-build-lanes.md § Traps "DEFECT SOLVED") ever 0x3s again (e.g.
# a Stevedore update reverted the patched shim), restore the warm/materialize
# Dockerfile targets from git history (c9586c1^).
#
# THE PAYLOADS WORK UNCHANGED; THE RESTORED TARGETS DO NOT (checked 2026-08-31,
# backlog #149). All ten of them mount the same five modules and neither of the
# two the tree has needed since:
#   * WindowsTargetArch.Common.psm1 — WindowsSourceBuild.Common THROWS AT IMPORT
#     without it (#116), so every restored RUN dies before its first line.
#   * WindowsTvm.Common.psm1 — build-tvm-from-source.ps1 throws without the
#     tvmmods mount (#134), so the TVM branch dies even once the import is fixed.
# Add both to the restored mount lists. Do NOT discover this during the outage.
#
# Original purpose — WARM-solve payload for the BuildKit lane: runs a heavy
# build, then hands its artifact delta off over WebDAV (Export-BuildHandoff).
# The driver runs the enclosing solve with NO exporter, so this container's
# snapshot is never finalized and the lost-shutdown-notification defect never
# fires.

[CmdletBinding()]
param(
    # Handoff name (tar becomes <endpoint>/bkhandoff/<Name>.tar).
    [Parameter(Mandatory)][string]$Name,
    # The build entry point to run before exporting.
    [Parameter(Mandatory)][string]$BuildScript,
    # Arguments for the build entry point, e.g. '-ResumeFrom','OpenCV'.
    [string[]]$BuildArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$t0 = Get-Date
# Child pwsh with -File, NOT `& $BuildScript @BuildArgs`: array splatting binds
# strictly BY POSITION, so a leading-dash element like '-ResumeFrom' arrives as
# the VALUE of parameter 1 ("positional parameter cannot be found" under
# CmdletBinding). -File re-parses the argv into named parameters.
& pwsh -NoProfile -ExecutionPolicy Bypass -File $BuildScript @BuildArgs
$exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
if ($exitCode) { throw "bk-warm: build '$BuildScript' failed (exit $exitCode)" }

# No -DisableNameChecking: every exported function uses an approved verb (the
# three build-*-all wrappers import this module bare and warn-free).
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1') -Force
Export-BuildHandoff -Since $t0 -Name $Name

# Reaching EOF IS success (same contract as every build script: pwsh -Command
# propagates the last native exit code otherwise).
exit 0
