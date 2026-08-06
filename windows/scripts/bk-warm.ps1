# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# RETIRED FROM THE DOCKERFILES (de-warming 2026-08-06, round 2): the
# ExportLayer-0x3 defect this pattern routed around was root-caused to the
# runhcs shim's hardcoded 30s tearDownTimeout (real heavy-churn teardown:
# ~117s measured) and is fixed by the patched shim in Stevedore\bin — all
# solves are direct now. KEPT (with bk-materialize.ps1 + the handoff helpers
# + their tests) as the tested rollback path: if the canary
# (docs/windows-builds.md § roadmap "DEFECT SOLVED") ever 0x3s again (e.g.
# a Stevedore update reverted the patched shim), restore the
# warm/materialize Dockerfile targets from git history (c9586c1^) and these
# payloads work unchanged.
#
# Original purpose — WARM-solve payload for the BuildKit lane: runs a heavy
# build, then hands its artifact delta off over WebDAV (Export-BuildHandoff).
# The driver runs the enclosing solve with NO exporter, so this container's
# snapshot is never finalized and the lost-shutdown-notification defect never
# fires.

#requires -Version 7.0
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
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1') -Force
Export-BuildHandoff -Since $t0 -Name $Name

# Reaching EOF IS success (same contract as every build script: pwsh -Command
# propagates the last native exit code otherwise).
exit 0
