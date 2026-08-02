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

# This directory holds two kinds of suite: zero-dependency ones written
# against TestHarness.psm1 (dot-sourced below) and Pester-style ones using
# Describe/BeforeAll. Dot-sourcing the latter throws "The BeforeAll command
# may only be used inside a Describe block" and aborts the whole run, so
# they are detected and handed to Pester instead. Without this the runner
# breaks the moment anyone adds a Pester suite next to a harness suite.
$pesterFailures = 0
$testFiles = Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name
foreach ($f in $testFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow

    $isPesterStyle = (Get-Content $f.FullName -Raw) -match '(?m)^\s*Describe\s'
    if (-not $isPesterStyle) {
        . $f.FullName
        continue
    }

    if (-not (Get-Module -ListAvailable -Name Pester)) {
        Write-Host '   SKIPPED (Pester-style suite; Pester is not installed)' -ForegroundColor Yellow
        continue
    }

    Import-Module Pester -ErrorAction Stop
    $pesterRun = Invoke-Pester -Path $f.FullName -PassThru -Quiet
    Write-Host ("   Pester: {0}/{1} passed" -f $pesterRun.PassedCount, $pesterRun.TotalCount) `
        -ForegroundColor $(if ($pesterRun.FailedCount -gt 0) { 'Red' } else { 'Green' })
    $pesterFailures += $pesterRun.FailedCount
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

if ($pesterFailures -gt 0) {
    Write-Host "  $pesterFailures Pester test(s) failed (see the per-file lines above)" -ForegroundColor Red
}

if ($failed.Count -gt 0 -or $pesterFailures -gt 0) { exit 1 }
exit 0
