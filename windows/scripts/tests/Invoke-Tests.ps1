# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Runs every *.Tests.ps1 in this directory against the shared modules and exits non-zero
# on any failure. Zero external dependencies (see TestHarness.psm1) — safe to run on the
# PS 5.1 container and the PS 7.x host alike, and as a CI/pre-build gate.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modDir = Join-Path (Split-Path $here -Parent) 'modules'

Import-Module (Join-Path $here 'TestHarness.psm1') -Force -DisableNameChecking
# Import SourceBuild FIRST, then Shared LAST: every module nested-imports Shared with
# -Force, which under PS 5.1 rebinds Shared into the nested scope and hides its exports
# from the top level. Importing Shared last restores them (same fix build-gstreamer uses).
Import-Module (Join-Path $modDir 'WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -Force -DisableNameChecking

Reset-TestState

$testFiles = Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name
foreach ($f in $testFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow
    . $f.FullName
}

$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
$passed = $results.Count - $failed.Count

Write-Host ''
Write-Host ('=' * 60)
$color = if ($failed.Count -gt 0) { 'Red' } else { 'Green' }
Write-Host " $($results.Count) tests | $passed passed | $($failed.Count) failed" -ForegroundColor $color
Write-Host ('=' * 60)
foreach ($x in $failed) {
    Write-Host "  FAIL [$($x.Group)] $($x.Name)" -ForegroundColor Red
    Write-Host "       $($x.Err)" -ForegroundColor Red
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
