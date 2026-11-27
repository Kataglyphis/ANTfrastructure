#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Runs a Pester suite at a pinned version, in its dialect; a failed, empty or passless run exits 1.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'

# Pester 3 and 4 take the legacy parameters; 5 and later need a configuration and report failures differently.
function Test-ModernPester {
    param([Parameter(Mandatory)][string]$Version)
    return ([version]$Version).Major -ge 5
}

# Get-SuiteFailure: one failed test or container, as the verdict prints it.
function Get-SuiteFailure {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$Name)
    $records = @($Item.ErrorRecord)
    return [pscustomobject]@{
        Name = $Name
        Message = ($records | ForEach-Object { $_.Exception.Message }) -join "`n"
        Stack = ($records | ForEach-Object { $_.ScriptStackTrace }) -join "`n"
    }
}

function Invoke-PesterRun {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$Modern)
    if (-not $Modern) { return Invoke-Pester -Path $Path -PassThru -Quiet }
    $config = New-PesterConfiguration
    $config.Run.Path = $Path
    $config.Run.PassThru = $true
    # Pester must not end the process itself: the verdict below decides the exit code.
    $config.Run.Exit = $false
    $config.Output.Verbosity = 'Normal'
    return Invoke-Pester -Configuration $config
}

# ConvertTo-SuiteResult: either dialect's result as one shape; $null stays $null.
function ConvertTo-SuiteResult {
    param($Run, [Parameter(Mandatory)][bool]$Modern)
    if ($null -eq $Run) { return $null }
    if ($Modern) {
        $failures = @($Run.Failed | ForEach-Object { Get-SuiteFailure -Item $_ -Name $_.ExpandedPath })
        # A file that fails discovery or its top-level BeforeAll reports no test at all, only a failed container.
        $failures += @($Run.Containers | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object {
                Get-SuiteFailure -Item $_ -Name "container $($_.Item)"
            })
        $containers = $Run.FailedContainersCount
    } else {
        $failures = @($Run.TestResult | Where-Object { -not $_.Passed } | ForEach-Object {
                [pscustomobject]@{ Name = "$($_.Describe) / $($_.Name)"; Message = $_.FailureMessage; Stack = $_.StackTrace }
            })
        $containers = 0
    }
    return [pscustomobject]@{
        Total = [int]$Run.TotalCount; Passed = [int]$Run.PassedCount; Failed = [int]$Run.FailedCount
        FailedContainers = [int]$containers; Failures = @($failures)
    }
}

function Get-SuiteExitCode {
    param($Result, [Parameter(Mandatory)][string]$Path)
    if ($null -eq $Result -or ($Result.Total -eq 0 -and $Result.FailedContainers -eq 0)) {
        Write-Host "::error::run-pester-suite: '$Path' matched no Pester test (TotalCount=0). A suite that runs nothing must not report success: check that the path exists in the checkout, that the file is named *.Tests.ps1, and that the checkout step actually fetched it."
        return 1
    }
    Write-Host "TOTAL=$($Result.Total) PASSED=$($Result.Passed) FAILED=$($Result.Failed) FAILED_CONTAINERS=$($Result.FailedContainers)"
    if ($Result.Failed -gt 0 -or $Result.FailedContainers -gt 0) {
        # The test name alone does not say what was compared; print message and stack too.
        foreach ($failure in $Result.Failures) {
            Write-Host "FAIL: $($failure.Name)"
            if ($failure.Message) { Write-Host "      $($failure.Message)" }
            if ($failure.Stack) { Write-Host "      $($failure.Stack)" }
        }
        return 1
    }
    if ($Result.Passed -lt 1) {
        Write-Host "::error::run-pester-suite: '$Path' had no passing test; skipped or pending tests are not execution evidence."
        return 1
    }
    return 0
}

$installer = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../windows/scripts/modules/WindowsCi.ModuleBootstrap.psm1')).Path
Import-Module $installer -ErrorAction Stop
$null = Install-PinnedPowerShellModule -Name Pester -Version $Version -SkipPublisherCheck
Import-Module Pester -RequiredVersion $Version -ErrorAction Stop
$modern = Test-ModernPester -Version $Version
$result = ConvertTo-SuiteResult -Run (Invoke-PesterRun -Path $Path -Modern $modern) -Modern $modern
# GitHub's pwsh wrapper exits with $LASTEXITCODE, which a passing suite's own native calls can leave nonzero.
exit (Get-SuiteExitCode -Result $result -Path $Path)
