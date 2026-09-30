#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Runs every *.Tests.ps1 here; a missing Pester fails the run so CI cannot go green on "0 tests".
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modDir = Join-Path (Split-Path $here -Parent) 'modules'

Import-Module (Join-Path $here 'TestHarness.psm1') -Force -DisableNameChecking
# -Force gives dev sessions fresh code; the modules' own nested imports never use it, so order does not matter.
Import-Module (Join-Path $modDir 'WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsBuildKit.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsBuildDriver.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsGstPlugins.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTesting.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsClang.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsScripts.Shared.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTargetArch.Common.psm1') -Force -DisableNameChecking
# Leaf modules sit outside the buildmods closure on purpose, but the suites test them directly.
Import-Module (Join-Path $modDir 'WindowsMeson.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsRustToolchain.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $modDir 'WindowsTvm.Common.psm1') -Force -DisableNameChecking

Reset-TestState

# Pester-style suites are detected by Pester-only keywords, never Describe, which TestHarness.psm1 also exports.
$pesterFailures = 0
$pesterPassed = 0
$pesterTotal = 0
$skippedSuites = @()
$pesterMinVersion = [version]'5.0'
$pesterAvailable = $null -ne (Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $pesterMinVersion } | Select-Object -First 1)
$testFiles = Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name
$harnessFiles = @()
$pesterFiles = @()
foreach ($f in $testFiles) {
    $isPesterStyle = (Get-Content $f.FullName -Raw) -match '(?m)^\s*(BeforeAll|BeforeEach|AfterAll|AfterEach|Context)\s'
    if ($isPesterStyle) { $pesterFiles += $f } else { $harnessFiles += $f }
}

# Harness suites run before Pester is imported: its Describe/It would shadow the harness and swallow failures.
foreach ($f in $harnessFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow
    . $f.FullName
}

# Pass 2: Pester suites.
foreach ($f in $pesterFiles) {
    Write-Host ''
    Write-Host "== $($f.Name) ==" -ForegroundColor Yellow

    if (-not $pesterAvailable) {
        Write-Host "   SKIPPED (Pester-style suite; Pester >= $pesterMinVersion is not installed)" -ForegroundColor Yellow
        $skippedSuites += $f.Name
        continue
    }

    Import-Module Pester -MinimumVersion $pesterMinVersion -ErrorAction Stop
    # Output.Verbosity 'None' replaces Pester 3/4's -Quiet and works on 5.x and 6.x.
    $pesterConf = New-PesterConfiguration
    $pesterConf.Run.Path = $f.FullName
    $pesterConf.Run.PassThru = $true
    $pesterConf.Output.Verbosity = 'None'
    $pesterRun = Invoke-Pester -Configuration $pesterConf
    Write-Host ("   Pester: {0}/{1} passed" -f $pesterRun.PassedCount, $pesterRun.TotalCount) `
        -ForegroundColor $(if ($pesterRun.FailedCount -gt 0) { 'Red' } else { 'Green' })
    foreach ($ft in @($pesterRun.Failed)) {
        Write-Host "   FAIL $($ft.ExpandedPath)" -ForegroundColor Red
        # The assertion text is the diagnosis; without it a red suite needs a second run.
        foreach ($er in @($ft.ErrorRecord)) { if ($er) { Write-Host "        $(($er.Exception.Message -split "`r?`n")[0])" -ForegroundColor DarkRed } }
    }
    $pesterFailures += $pesterRun.FailedCount
    $pesterPassed += $pesterRun.PassedCount
    $pesterTotal += $pesterRun.TotalCount
}

$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
$passed = $results.Count - $failed.Count + $pesterPassed
$total = $results.Count + $pesterTotal
$failCount = $failed.Count + $pesterFailures

Write-Host ''
Write-Host ('=' * 60)
$color = if ($failCount -gt 0) { 'Red' } else { 'Green' }
Write-Host " $total tests | $passed passed | $failCount failed" -ForegroundColor $color
Write-Host ('=' * 60)
foreach ($x in $failed) {
    Write-Host "  FAIL [$($x.Group)] $($x.Name)" -ForegroundColor Red
    Write-Host "       $($x.Err)" -ForegroundColor Red
}

if ($pesterFailures -gt 0) {
    Write-Host "  $pesterFailures Pester test(s) failed (see the per-file lines above)" -ForegroundColor Red
}

# A skipped suite is a failed gate, or a host without Pester reports a green "0 tests" run.
if ($skippedSuites.Count -gt 0) {
    Write-Host "  $($skippedSuites.Count) suite(s) SKIPPED (Pester >= $pesterMinVersion required):" -ForegroundColor Red
    foreach ($s in $skippedSuites) { Write-Host "    $s" -ForegroundColor Red }
    Write-Host '  Install it with: Install-Module Pester -MinimumVersion 5.7 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
}

# ~1% below the measured count: raise it when suites grow, never lower it to make a red run green.
$minTests = 797
if ($total -lt $minTests) {
    Write-Host "  FLOOR: only $total test(s) ran, expected at least $minTests -- suites were not discovered (glob, working directory, or a moved suite dir), not 'nothing to do'." -ForegroundColor Red
    exit 1
}

if ($failed.Count -gt 0 -or $pesterFailures -gt 0 -or $skippedSuites.Count -gt 0) { exit 1 }
exit 0
