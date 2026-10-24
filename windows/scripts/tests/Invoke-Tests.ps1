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
    [string]$ResultFile,
    [string]$SummaryFile = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modDir = Join-Path (Split-Path $here -Parent) 'modules'

$testFiles = @(Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name)
if ($Only) { $testFiles = @($testFiles | Where-Object { $_.Name -eq $Only }) }
# ~1% below the measured 2724 tests: raise it when suites grow, never lower it to make a red run green.
$minTests = 2698

function New-TestTally {
    param([int]$Total, [int]$Passed, [int]$PesterFailures, [object[]]$Failed = @(), [string[]]$Skipped = @(),
        [Collections.IDictionary]$CoverageData = @{ Reports = @(); Failures = @() })
    return [ordered]@{
        Total = $Total
        Passed = $Passed
        PesterFailures = $PesterFailures
        Failed = @($Failed | ForEach-Object { [pscustomobject]@{ Group = $_.Group; Name = $_.Name; Err = $_.Err } })
        Skipped = @($Skipped)
        Coverage = @($CoverageData.Reports)
        CoverageFailures = @($CoverageData.Failures)
    }
}

function Merge-TestTallies {
    param([object[]]$Tallies)
    $total = 0; $passed = 0; $pesterFailures = 0
    $failed = @(); $skipped = @(); $coverage = @(); $coverageFailures = @()
    foreach ($item in $Tallies) {
        $total += [int]$item.Total
        $passed += [int]$item.Passed
        $pesterFailures += [int]$item.PesterFailures
        $failed += @($item.Failed)
        $skipped += @($item.Skipped)
        $coverage += @($item.Coverage)
        $coverageFailures += @($item.CoverageFailures)
    }
    return New-TestTally -Total $total -Passed $passed -PesterFailures $pesterFailures -Failed $failed `
        -Skipped $skipped -CoverageData @{ Reports = $coverage; Failures = $coverageFailures }
}

function Get-CoverageInventoryFailures {
    param([object[]]$Coverage)
    $targets = Get-CoverageTargets
    $failures = @()
    foreach ($suite in $targets.Keys) {
        $module = $targets[$suite].Module
        $reportsForPair = @($Coverage | Where-Object { $_.Suite -eq $suite -and $_.Module -eq $module })
        if ($reportsForPair.Count -ne 1) {
            $failures += "expected one $suite / $module report, got $($reportsForPair.Count)"
        }
    }
    if ($Coverage.Count -ne $targets.Count) {
        $failures += "expected $($targets.Count) distinct coverage reports, got $($Coverage.Count)"
    }
    return $failures
}

function Get-TestExitCode {
    param([Collections.IDictionary]$Tally, [string[]]$CoverageFailures, [string[]]$Broken)
    if ([int]$Tally.Total -lt $minTests -or @($Tally.Failed).Count -gt 0 -or [int]$Tally.PesterFailures -gt 0 -or
        @($Tally.Skipped).Count -gt 0 -or $Broken.Count -gt 0 -or $CoverageFailures.Count -gt 0) { return 1 }
    return 0
}

function Write-CoverageDetails {
    param([object[]]$Reports, [string[]]$Failures)
    foreach ($item in $Reports) {
        Write-Host ("  COVERAGE {0}: {1:N1}% ({2}/{3} commands, floor {4}%)" -f $item.Module, $item.Percent,
            $item.Executed, $item.Analyzed, $item.MinimumPercent)
        Write-Host "    $($item.ReportPath)"
    }
    foreach ($failure in $Failures) { Write-Host "  COVERAGE FAIL $failure" -ForegroundColor Red }
}

function Write-TestFailure {
    param([string]$Name, [string[]]$Message, [string]$Indent = '  ', [ConsoleColor]$DetailColor = 'Red')
    Write-Host "${Indent}FAIL $Name" -ForegroundColor Red
    foreach ($line in $Message) {
        if ($line) { Write-Host "${Indent}     $line" -ForegroundColor $DetailColor }
    }
}

function Write-TallyDetails {
    param([Collections.IDictionary]$Tally, [string[]]$CoverageFailures, [string[]]$Broken)
    foreach ($item in @($Tally.Failed)) {
        Write-TestFailure -Name "[$($item.Group)] $($item.Name)" -Message @($item.Err)
    }
    if ($Tally.PesterFailures -gt 0) {
        Write-Host "  $($Tally.PesterFailures) Pester test(s) failed (see the per-file lines above)" -ForegroundColor Red
    }
    Write-CoverageDetails -Reports @($Tally.Coverage) -Failures $CoverageFailures
    # A skipped suite is a failed gate, or a host without Pester reports a green "0 tests" run.
    if (@($Tally.Skipped).Count -gt 0) {
        Write-Host "  $(@($Tally.Skipped).Count) suite(s) SKIPPED (Pester >= 6.2 required):" -ForegroundColor Red
        foreach ($suite in @($Tally.Skipped)) { Write-Host "    $suite" -ForegroundColor Red }
        Write-Host '  Install it with: Install-Module Pester -MinimumVersion 6.2 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
    }
    if ($Broken.Count -gt 0) {
        Write-Host "  $($Broken.Count) suite(s) wrote no tallies and did not finish: $($Broken -join ', ')" -ForegroundColor Red
    }
    if ([int]$Tally.Total -lt $minTests) {
        Write-Host "  FLOOR: only $($Tally.Total) test(s) ran, expected at least $minTests -- suites were not discovered (glob, working directory, or a moved suite dir), not 'nothing to do'." -ForegroundColor Red
    }
}

# Prints the one summary and returns the exit code: either path's tallies, the sum of every child's on the parallel one.
function Write-TestSummary {
    param([Parameter(Mandatory)][Collections.IDictionary]$Tally, [string[]]$Broken = @(), [string]$SummaryFile = '',
        [switch]$RequireCoverageTargets)
    $Total = [int]$Tally.Total
    $Passed = [int]$Tally.Passed
    $Coverage = @($Tally.Coverage)
    $CoverageFailures = @($Tally.CoverageFailures)
    if ($RequireCoverageTargets) {
        $CoverageFailures += @(Get-CoverageInventoryFailures -Coverage $Coverage)
    }
    $failCount = @($Tally.Failed).Count + [int]$Tally.PesterFailures
    $exitCode = Get-TestExitCode -Tally $Tally -CoverageFailures $CoverageFailures -Broken $Broken
    Write-Host ''
    Write-Host ('=' * 60)
    $color = if ($exitCode -ne 0) { 'Red' } else { 'Green' }
    Write-Host " $Total tests | $Passed passed | $failCount failed" -ForegroundColor $color
    Write-Host ('=' * 60)
    Write-TallyDetails -Tally $Tally -CoverageFailures $CoverageFailures -Broken $Broken
    $summaryPath = if ($SummaryFile) { $SummaryFile } else {
        $repoRoot = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
        Join-Path $repoRoot ("logs\windows-tests\summary-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
    }
    $parent = Split-Path -Parent $summaryPath
    if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop }
    $tally['RunAtUtc'] = [datetime]::UtcNow.ToString('o')
    $tally['FailedCount'] = $failCount
    $tally['Broken'] = @($Broken)
    $tally['MinTests'] = $minTests
    $tally['FloorMet'] = $Total -ge $minTests
    $tally['CoverageFailures'] = @($CoverageFailures)
    $tally['CoverageFloorMet'] = $CoverageFailures.Count -eq 0
    $tally['ExitCode'] = $exitCode
    ConvertTo-Json -InputObject $tally -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding utf8 -ErrorAction Stop
    Write-Host "Run summary: $summaryPath"
    return $exitCode
}

function Get-CoverageTargets {
    return @{
        'WindowsAppRunner.Common.Tests.ps1' = @{ Module = 'WindowsAppRunner.Common.psm1'; MinimumPercent = 85 }
        'WindowsBuildSweep.Common.Tests.ps1' = @{ Module = 'WindowsBuildSweep.Common.psm1'; MinimumPercent = 90 }
        'WindowsAgenticLoop.Common.Tests.ps1' = @{ Module = 'WindowsAgenticLoop.Common.psm1'; MinimumPercent = 60 }
        'WindowsConfig.Common.Tests.ps1' = @{ Module = 'WindowsConfig.Common.psm1'; MinimumPercent = 90 }
        'WindowsOnnx.Common.Tests.ps1' = @{ Module = 'WindowsOnnx.Common.psm1'; MinimumPercent = 100 }
        'WindowsRepoHygiene.Common.Tests.ps1' = @{ Module = 'WindowsRepoHygiene.Common.psm1'; MinimumPercent = 85 }
        'WindowsPerfBaseline.Common.Tests.ps1' = @{ Module = 'WindowsPerfBaseline.Common.psm1'; MinimumPercent = 90 }
        'WindowsClang.Common.Tests.ps1' = @{ Module = 'WindowsClang.Common.psm1'; MinimumPercent = 80 }
        'WindowsMsix.Common.Tests.ps1' = @{ Module = 'WindowsMsix.Common.psm1'; MinimumPercent = 80 }
        'WindowsSlang.Common.Tests.ps1' = @{ Module = 'WindowsSlang.Common.psm1'; MinimumPercent = 65 }
        'WindowsWasmOpt.Common.Tests.ps1' = @{ Module = 'WindowsWasmOpt.Common.psm1'; MinimumPercent = 80 }
        'WindowsWebDav.Common.Tests.ps1' = @{ Module = 'WindowsWebDav.Common.psm1'; MinimumPercent = 90 }
        'WindowsMsix.Signing.Tests.ps1' = @{ Module = 'WindowsMsix.Signing.psm1'; MinimumPercent = 80 }
        'WindowsContainerImage.Bootstrap.Coverage.Tests.ps1' = @{ Module = 'WindowsContainerImage.Bootstrap.psm1'; MinimumPercent = 100 }
    }
}

# NOT covered: Pester's instrumentation internals; this verifies the saved module report and measured command counts.
function Get-CoberturaModuleFailure {
    param([Parameter(Mandatory)][string]$ReportPath, [Parameter(Mandatory)][string]$ExpectedClass)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
    $settings.XmlResolver = $null
    try {
        $reader = [Xml.XmlReader]::Create($ReportPath, $settings)
        try {
            $document = [xml]::new()
            $document.XmlResolver = $null
            $document.Load($reader)
        } finally { $reader.Dispose() }
    } catch { return "invalid Cobertura XML: $($_.Exception.Message)" }
    if ($document.DocumentElement.Name -ne 'coverage') { return 'Cobertura report has no coverage root' }
    $classes = @($document.SelectNodes('/coverage/packages/package/classes/class'))
    if ($classes.Count -ne 1) { return "expected one Cobertura class, got $($classes.Count)" }
    $classPath = $classes[0].GetAttribute('filename') -replace '\\', '/'
    if ($classPath -ne $ExpectedClass) { return "Cobertura class is $classPath, expected $ExpectedClass" }
    if (@($classes[0].SelectNodes('./lines/line')).Count -eq 0) { return 'Cobertura class has no measured lines' }
    return ''
}

function Get-CoverageFailure {
    param([object]$Coverage, [Parameter(Mandatory)][string]$ReportPath,
        [Parameter(Mandatory)][string]$ExpectedClass, [Parameter(Mandatory)][int]$MinimumPercent)
    if ($null -eq $Coverage) { return 'Pester returned no coverage result' }
    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { return "coverage report is missing: $ReportPath" }
    if ((Get-Item -LiteralPath $ReportPath).Length -eq 0) { return "coverage report is empty: $ReportPath" }
    $reportFailure = Get-CoberturaModuleFailure -ReportPath $ReportPath -ExpectedClass $ExpectedClass
    if ($reportFailure) { return $reportFailure }
    if ([int]$Coverage.FilesAnalyzedCount -ne 1) { return "expected one measured module, got $($Coverage.FilesAnalyzedCount)" }
    if ([int]$Coverage.CommandsAnalyzedCount -le 0) { return 'Pester analyzed no commands' }
    if ([int]$Coverage.CommandsExecutedCount -le 0) { return 'Pester executed no measured commands' }
    if ([int]$Coverage.CommandsExecutedCount -gt [int]$Coverage.CommandsAnalyzedCount) { return 'coverage counts are inconsistent' }
    if ([double]$Coverage.CoveragePercent -lt $MinimumPercent) {
        return ("coverage {0:N1}% is below {1}%" -f [double]$Coverage.CoveragePercent, $MinimumPercent)
    }
    return ''
}

function Invoke-PesterSuites {
    param([object[]]$Files, [bool]$Available, [version]$MinimumVersion)
    $failures = 0
    $passed = 0
    $total = 0
    $skipped = @()
    $coverage = @()
    $coverageFailures = @()
    $coverageTargets = Get-CoverageTargets
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
        $target = $coverageTargets[$file.Name]
        if ($target) {
            $repoRoot = Split-Path (Split-Path (Split-Path $here -Parent) -Parent) -Parent
            $coverageDir = Join-Path $repoRoot 'logs/windows-tests'
            $null = New-Item -ItemType Directory -Force -Path $coverageDir -ErrorAction Stop
            $reportPath = Join-Path $coverageDir ("coverage-{0}-{1}-{2}.xml" -f $file.BaseName,
                (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $PID)
            $configuration.CodeCoverage.Enabled = $true
            $configuration.CodeCoverage.Path = Join-Path $modDir $target.Module
            $configuration.CodeCoverage.OutputFormat = 'Cobertura'
            $configuration.CodeCoverage.OutputPath = $reportPath
            $configuration.CodeCoverage.ReportRoot = $repoRoot
            $configuration.CodeCoverage.CoveragePercentTarget = $target.MinimumPercent
        }
        $run = Invoke-Pester -Configuration $configuration
        if ($target) {
            $failure = Get-CoverageFailure -Coverage $run.CodeCoverage -ReportPath $reportPath `
                -ExpectedClass "windows/scripts/modules/$($target.Module)" `
                -MinimumPercent $target.MinimumPercent
            $coverage += [pscustomobject]@{
                Suite = $file.Name
                Module = $target.Module
                Percent = [double]$run.CodeCoverage.CoveragePercent
                MinimumPercent = $target.MinimumPercent
                Analyzed = [int]$run.CodeCoverage.CommandsAnalyzedCount
                Executed = [int]$run.CodeCoverage.CommandsExecutedCount
                ReportPath = $reportPath
            }
            if ($failure) {
                $coverageFailures += "$($file.Name): $failure"
                Write-Host "   COVERAGE FAIL $failure" -ForegroundColor Red
            }
        }
        Write-Host ("   Pester: {0}/{1} passed" -f $run.PassedCount, $run.TotalCount) `
            -ForegroundColor $(if ($run.FailedCount -gt 0) { 'Red' } else { 'Green' })
        foreach ($failedTest in @($run.Failed)) {
            $messages = @($failedTest.ErrorRecord | Where-Object { $_ } |
                ForEach-Object { ($_.Exception.Message -split "`r?`n")[0] })
            Write-TestFailure -Name $failedTest.ExpandedPath -Message $messages -Indent '   ' -DetailColor DarkRed
        }
        $failures += $run.FailedCount
        $passed += $run.PassedCount
        $total += $run.TotalCount
    }
    return [pscustomobject]@{ Failures = $failures; Passed = $passed; Total = $total; Skipped = $skipped;
        Coverage = $coverage; CoverageFailures = $coverageFailures }
}

# One pwsh per file, not batches: a suite that swaps a module for a temp copy broke the next suite in its batch.
if (-not $Only -and $Jobs -gt 1 -and $testFiles.Count -gt 1) {
    Import-Module (Join-Path $modDir 'WindowsFanOut.Common.psm1') -Force -DisableNameChecking
    Write-Host "Invoke-Tests: $($testFiles.Count) files, $Jobs at a time, each in its own pwsh (-Jobs 1 runs them in this process)"
    $sets = @($testFiles | ForEach-Object { , @('-Jobs', '1', '-Only', $_.Name) })
    $tallies = @(); $broken = @()
    foreach ($child in @(Invoke-PwshFanOut -Script $PSCommandPath -ArgumentSets $sets -Jobs $Jobs)) {
        $child.Output | Write-Host
        # A child that wrote no tallies died before its summary: its suite counts as unrun, never as green.
        if ($null -eq $child.Result) { $broken += $testFiles[$child.Index].Name; continue }
        $tallies += $child.Result | ConvertFrom-Json
    }
    $tally = Merge-TestTallies -Tallies $tallies
    exit (Write-TestSummary -Tally $tally -Broken $broken -SummaryFile $SummaryFile -RequireCoverageTargets)
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
$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
$harnessTally = New-TestTally -Total $results.Count -Passed ($results.Count - $failed.Count) `
    -PesterFailures 0 -Failed $failed
$pesterTally = New-TestTally -Total $pesterReport.Total -Passed $pesterReport.Passed `
    -PesterFailures $pesterReport.Failures -Skipped $pesterReport.Skipped `
    -CoverageData @{ Reports = $pesterReport.Coverage; Failures = $pesterReport.CoverageFailures }
$tally = Merge-TestTallies -Tallies @($harnessTally, $pesterTally)

# A child hands its tallies to the parent, which prints the one summary and applies the floor to the sum.
if ($ResultFile) {
    ConvertTo-Json -InputObject $tally -Depth 4 | Set-Content -LiteralPath $ResultFile
    if ($tally.Failed.Count -gt 0 -or $tally.PesterFailures -gt 0 -or $tally.Skipped.Count -gt 0 -or
        $tally.CoverageFailures.Count -gt 0) { exit 1 }
    exit 0
}

exit (Write-TestSummary -Tally $tally -SummaryFile $SummaryFile -RequireCoverageTargets:(-not [bool]$Only))
