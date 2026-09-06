# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python documentation builder for Windows

.DESCRIPTION
    Builds Sphinx documentation with coverage reports.
    Uses shared modules from ContainerHub.

.PARAMETER PythonVersion
    Python version to use (default: "3.13")

.EXAMPLE
    Invoke-CiBuildDocs.ps1
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.13"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot

# #141: shared preamble — context/log/wrappers/uv delegates come from
# New-CiSession (Initialize-CiEnvironment.ps1).
$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates

Write-CiLog "Using Python version: $PythonVersion for docs build"

$VENV_DIR = Join-Path $repoRoot ".venv-docs"

try {
    if (Test-Path $VENV_DIR) {
        Write-CiLog "Using existing docs venv at $VENV_DIR"
    } else {
        Write-CiLog "Creating docs venv at $VENV_DIR"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-docs" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null
    }

    Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython

    Copy-Item (Join-Path $repoRoot "README.md") (Join-Path $repoRoot "docs\source\README.md") -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $repoRoot "CHANGELOG.md") (Join-Path $repoRoot "docs\source\CHANGELOG.md") -Force -ErrorAction SilentlyContinue

    $SRC = Join-Path $repoRoot "docs\test_results"
    $STATIC_DIR = Join-Path $repoRoot "docs\source\_static"
    $COVERAGE_DST = Join-Path $STATIC_DIR "coverage"
    $TEST_RESULTS_DST = Join-Path $STATIC_DIR "test_results"

    New-Item -ItemType Directory -Force $COVERAGE_DST | Out-Null
    New-Item -ItemType Directory -Force $TEST_RESULTS_DST | Out-Null

    Write-CiLog "Looking for coverage HTML in $SRC ..."
    $coverageHtmlDir = Join-Path $SRC "coverage-html-$PythonVersion"
    if (Test-Path $coverageHtmlDir) {
        Copy-Item "$coverageHtmlDir\*" $COVERAGE_DST -Recurse -Force
        Write-CiLog "Copied $coverageHtmlDir -> $COVERAGE_DST"
    } elseif (Test-Path (Join-Path $SRC "coverage")) {
        Copy-Item "$SRC\coverage\*" $COVERAGE_DST -Recurse -Force
        Write-CiLog "Copied $SRC\coverage -> $COVERAGE_DST"
    } elseif (Test-Path (Join-Path $SRC "htmlcov")) {
        Copy-Item "$SRC\htmlcov\*" $COVERAGE_DST -Recurse -Force
        Write-CiLog "Copied $SRC\htmlcov -> $COVERAGE_DST"
    }

    $coverageXml = Join-Path $SRC "coverage-$PythonVersion.xml"
    if (Test-Path $coverageXml) {
        Copy-Item $coverageXml (Join-Path $STATIC_DIR "coverage.xml") -Force
        Write-CiLog "Copied coverage-$PythonVersion.xml -> coverage.xml"
    } elseif (Test-Path (Join-Path $SRC "coverage.xml")) {
        Copy-Item (Join-Path $SRC "coverage.xml") (Join-Path $STATIC_DIR "coverage.xml") -Force
        Write-CiLog "Copied coverage.xml"
    }

    Write-CiLog "Copying pytest HTML reports..."
    Get-ChildItem -Path $SRC -Filter "pytest-report-*.html" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $TEST_RESULTS_DST -Force
        Write-CiLog "Copied $($_.Name) to $TEST_RESULTS_DST"
    }

    Get-ChildItem -Path $SRC -Filter "report-*.xml" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $TEST_RESULTS_DST -Force
        Write-CiLog "Copied $($_.Name) to $TEST_RESULTS_DST"
    }

    Get-ChildItem -Path $SRC -Filter "pytest-report-*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $STATIC_DIR -Force
    }

    Set-Location (Join-Path $repoRoot "docs")
    Invoke-BuildExternal -Context $script:BuildContext -File "make" -Parameters @("html") | Out-Null

    Write-CiLog "=== Docs build completed ==="

} finally {
    Remove-UvProjectEnvironment -EnvPath $VENV_DIR -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Write-BuildSummary -Context $script:BuildContext
    Close-BuildLog -Context $script:BuildContext
}

