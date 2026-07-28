# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python CI test runner for Windows

.DESCRIPTION
    Runs tests across multiple Python versions with coverage reporting.
    Uses shared modules from Kataglyphis-ContainerHub.

.PARAMETER PythonVersions
    Array of Python versions to test (default: @("3.13", "3.14", "3.14t"))

.PARAMETER PackageName
    Name of the package to test (derived from pyproject.toml if not specified)

.PARAMETER LogDir
    Directory for log files (default: "logs")

.PARAMETER StopOnError
    Stop on first error instead of continuing

.EXAMPLE
    Invoke-CiTests.ps1 -PythonVersions @("3.13", "3.14") -PackageName "my_package"
#>

[CmdletBinding()]
Param(
    [string[]]$PythonVersions = @("3.13", "3.14", "3.14t"),
    [string]$PackageName = "",
    [string]$LogDir = "logs",
    [switch]$StopOnError
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot

$PackageName = Get-PyprojectPackageName -RepoRoot $repoRoot -Default $PackageName

$script:BuildContext = New-BuildContext -Workspace $repoRoot -LogDir $LogDir -StopOnError:$StopOnError
$script:BuildContext.SuppressConsoleOutput = $false
$logPath = $script:BuildContext.LogPath
$script:CreatedUvEnvs = New-Object System.Collections.Generic.List[string]
$script:Results = $script:BuildContext.Results

function Close-Log { Close-BuildLog -Context $script:BuildContext }
function Write-Log { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
function Write-LogWarning { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }
function Write-LogError { param([string]$Message); Write-BuildLogError -Context $script:BuildContext -Message $Message }
function Write-LogSuccess { param([string]$Message); Write-BuildLogSuccess -Context $script:BuildContext -Message $Message }

Open-BuildLog -Context $script:BuildContext

Write-Log "=== Python CI Test Matrix (Windows) ==="
Write-Log "Repo root: $repoRoot"
Write-Log "Package name: $PackageName"
Write-Log "Python versions: $($PythonVersions -join ', ')"
Write-Log "Logging all output to: $logPath"

function New-UvEnvironment {
    param(
        [string]$PythonVersion,
        [string]$EnvName
    )
    $envPath = New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName $EnvName -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    $script:CreatedUvEnvs.Add($envPath) | Out-Null
    return $envPath
}

function Remove-UvEnvironment {
    param([string]$EnvPath)
    Remove-UvProjectEnvironment -EnvPath $EnvPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
}

$uvDelegates = New-UvBuildDelegates -Context $script:BuildContext
$script:UvCommandRunner = $uvDelegates.CommandRunner
$script:UvLogInfo = $uvDelegates.LogInfo
$script:UvLogWarning = $uvDelegates.LogWarning

$experimentalVersions = @("3.14t")

function Test-ExperimentalPython {
    param([string]$Version)
    return $experimentalVersions -contains $Version
}

function New-TestResultsDir {
    New-Item -ItemType Directory -Force (Join-Path $repoRoot "docs\test_results") | Out-Null
}

try {
    New-TestResultsDir

    foreach ($version in $PythonVersions) {
        # Experimental Python (e.g. 3.14t free-threaded) is permitted to fail without gating CI.
        $allowFailure = Test-ExperimentalPython -Version $version

        Invoke-BuildStep -Context $script:BuildContext -StepName "Python $version - Tests" -AllowFailure:$allowFailure -Script {
            Write-Log "--- Python $version ---"
            $envPath = New-UvEnvironment -PythonVersion $version -EnvName ".venv-$version"

            try {
                Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython

                $testArgs = @(
                    "run", "pytest", "tests/unit", "-v",
                    "--cov=$PackageName",
                    "--cov-report=term-missing",
                    "--cov-report=html:docs/test_results/coverage-html-$version",
                    "--cov-report=xml:docs/test_results/coverage-$version.xml",
                    "--junitxml=docs/test_results/report-$version.xml",
                    "--html=docs/test_results/pytest-report-$version.html",
                    "--self-contained-html",
                    "--md-report",
                    "--md-report-verbose=1",
                    "--md-report-output",
                    "docs/test_results/pytest-report-$version.md"
                )

                Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $testArgs | Out-Null

                Invoke-BuildOptional -Context $script:BuildContext -Name "cprofile demo" -Script {
                    Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("run", "python", "bench/demo_cprofile.py") | Out-Null
                }
                Invoke-BuildOptional -Context $script:BuildContext -Name "line_profiler demo" -Script {
                    Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("run", "python", "bench/demo_line_profiler.py") | Out-Null
                }
                Invoke-BuildOptional -Context $script:BuildContext -Name "pytest-benchmark" -Script {
                    Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("run", "pytest", "bench/demo_pytest_benchmark.py") | Out-Null
                }
            } finally {
                Remove-UvEnvironment -EnvPath $envPath
            }
        } | Out-Null
    }

    Write-Log "=== CI Tests completed ==="

} finally {
    foreach ($envPath in $script:CreatedUvEnvs) {
        Remove-UvEnvironment -EnvPath $envPath
    }

    Write-BuildSummary -Context $script:BuildContext
    Close-Log

    if ($script:Results.Failed.Count -gt 0) {
        exit 1
    }
}
