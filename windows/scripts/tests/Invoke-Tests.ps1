#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Runs every *.Tests.ps1 here; a missing Pester fails the run so CI cannot go green on "0 tests".
[CmdletBinding()]
param(
    # Test files at once, each in its own pwsh; 1 runs every file in this process, as before.
    [ValidateRange(1, 1024)]
    [int]$Jobs = [Environment]::ProcessorCount,
    # Internal: the one test file a child runs.
    [string]$Only,
    # Internal: where a child writes its tallies for the parent.
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modDir = Join-Path (Split-Path $here -Parent) 'modules'

$testFiles = @(Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name)
if ($Only) { $testFiles = @($testFiles | Where-Object { $_.Name -eq $Only }) }
# ~1% below the measured count: raise it when suites grow, never lower it to make a red run green.
$minTests = 2442

# Prints the one summary and returns the exit code: either path's tallies, the sum of every child's on the parallel one.
function Write-TestSummary {
    param([int]$Total, [int]$Passed, [int]$PesterFailures, [object[]]$Failed = @(), [string[]]$Skipped = @(), [string[]]$Broken = @())
    $failCount = @($Failed).Count + $PesterFailures
    Write-Host ''
    Write-Host ('=' * 60)
    $color = if ($failCount -gt 0 -or @($Broken).Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host " $Total tests | $Passed passed | $failCount failed" -ForegroundColor $color
    Write-Host ('=' * 60)
    foreach ($x in @($Failed)) {
        Write-Host "  FAIL [$($x.Group)] $($x.Name)" -ForegroundColor Red
        Write-Host "       $($x.Err)" -ForegroundColor Red
    }
    if ($PesterFailures -gt 0) {
        Write-Host "  $PesterFailures Pester test(s) failed (see the per-file lines above)" -ForegroundColor Red
    }
    # A skipped suite is a failed gate, or a host without Pester reports a green "0 tests" run.
    if (@($Skipped).Count -gt 0) {
        Write-Host "  $(@($Skipped).Count) suite(s) SKIPPED (Pester >= 6.2 required):" -ForegroundColor Red
        foreach ($s in @($Skipped)) { Write-Host "    $s" -ForegroundColor Red }
        Write-Host '  Install it with: Install-Module Pester -MinimumVersion 6.2 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
    }
    if (@($Broken).Count -gt 0) {
        Write-Host "  $(@($Broken).Count) suite(s) wrote no tallies and did not finish: $($Broken -join ', ')" -ForegroundColor Red
    }
    if ($Total -lt $minTests) {
        Write-Host "  FLOOR: only $Total test(s) ran, expected at least $minTests -- suites were not discovered (glob, working directory, or a moved suite dir), not 'nothing to do'." -ForegroundColor Red
        return 1
    }
    if ($failCount -gt 0 -or @($Skipped).Count -gt 0 -or @($Broken).Count -gt 0) { return 1 }
    return 0
}

function Invoke-PesterSuites {
    param([object[]]$Files, [bool]$Available, [version]$MinimumVersion)
    $failures = 0
    $passed = 0
    $total = 0
    $skipped = @()
    foreach ($file in $Files) {
        Write-Host ''
        Write-Host "== $($file.Name) ==" -ForegroundColor Yellow
        if (-not $Available) {
            Write-Host "   SKIPPED (Pester-style suite; Pester >= $MinimumVersion is not installed)" -ForegroundColor Yellow
            $skipped += $file.Name
            continue
        }
        Import-Module Pester -MinimumVersion $MinimumVersion -ErrorAction Stop
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = $file.FullName
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'None'
        $run = Invoke-Pester -Configuration $configuration
        Write-Host ("   Pester: {0}/{1} passed" -f $run.PassedCount, $run.TotalCount) `
            -ForegroundColor $(if ($run.FailedCount -gt 0) { 'Red' } else { 'Green' })
        foreach ($failedTest in @($run.Failed)) {
            Write-Host "   FAIL $($failedTest.ExpandedPath)" -ForegroundColor Red
            foreach ($errorRecord in @($failedTest.ErrorRecord)) {
                if ($errorRecord) { Write-Host "        $(($errorRecord.Exception.Message -split "`r?`n")[0])" -ForegroundColor DarkRed }
            }
        }
        $failures += $run.FailedCount
        $passed += $run.PassedCount
        $total += $run.TotalCount
    }
    return [pscustomobject]@{ Failures = $failures; Passed = $passed; Total = $total; Skipped = $skipped }
}

# One pwsh per file, not batches: a suite that swaps a module for a temp copy broke the next suite in its batch.
if (-not $Only -and $Jobs -gt 1 -and $testFiles.Count -gt 1) {
    Import-Module (Join-Path $modDir 'WindowsFanOut.Common.psm1') -Force -DisableNameChecking
    Write-Host "Invoke-Tests: $($testFiles.Count) files, $Jobs at a time, each in its own pwsh (-Jobs 1 runs them in this process)"
    $sets = @($testFiles | ForEach-Object { , @('-Jobs', '1', '-Only', $_.Name) })
    $total = 0; $passed = 0; $pesterFailures = 0
    $failed = @(); $skippedSuites = @(); $broken = @()
    foreach ($child in @(Invoke-PwshFanOut -Script $PSCommandPath -ArgumentSets $sets -Jobs $Jobs)) {
        $child.Output | Write-Host
        # A child that wrote no tallies died before its summary: its suite counts as unrun, never as green.
        if ($null -eq $child.Result) { $broken += $testFiles[$child.Index].Name; continue }
        $r = $child.Result | ConvertFrom-Json
        $total += $r.Total; $passed += $r.Passed; $pesterFailures += $r.PesterFailures
        $failed += @($r.Failed); $skippedSuites += @($r.Skipped)
    }
    exit (Write-TestSummary -Total $total -Passed $passed -PesterFailures $pesterFailures -Failed $failed -Skipped $skippedSuites -Broken $broken)
}

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
$pesterMinVersion = [version]'6.2'
$pesterAvailable = $null -ne (Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version -ge $pesterMinVersion } | Select-Object -First 1)
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

$pesterReport = Invoke-PesterSuites -Files $pesterFiles -Available $pesterAvailable -MinimumVersion $pesterMinVersion
$pesterFailures = $pesterReport.Failures
$pesterPassed = $pesterReport.Passed
$pesterTotal = $pesterReport.Total
$skippedSuites = $pesterReport.Skipped
$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
$passed = $results.Count - $failed.Count + $pesterPassed
$total = $results.Count + $pesterTotal

# A child hands its tallies to the parent, which prints the one summary and applies the floor to the sum.
if ($ResultFile) {
    [pscustomobject]@{
        Total = $total; Passed = $passed; PesterFailures = $pesterFailures
        Failed = @($failed | ForEach-Object { [pscustomobject]@{ Group = $_.Group; Name = $_.Name; Err = $_.Err } })
        Skipped = @($skippedSuites)
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultFile
    if ($failed.Count -gt 0 -or $pesterFailures -gt 0 -or $skippedSuites.Count -gt 0) { exit 1 }
    exit 0
}

exit (Write-TestSummary -Total $total -Passed $passed -PesterFailures $pesterFailures -Failed $failed -Skipped $skippedSuites)
