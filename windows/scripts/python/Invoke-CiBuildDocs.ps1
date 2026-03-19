<#
.SYNOPSIS
    Generic Python documentation builder for Windows

.DESCRIPTION
    Builds Sphinx documentation with coverage reports.
    Uses shared modules from Kataglyphis-ContainerHub.

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

$scriptDir = $PSScriptRoot
$containerHubModulesPath = Join-Path $scriptDir "..\modules"
$buildCommonModulePath = Join-Path $containerHubModulesPath "WindowsBuild.Common.psm1"
$uvCommonModulePath = Join-Path $containerHubModulesPath "WindowsUv.Common.psm1"

if (-not (Test-Path -Path $buildCommonModulePath)) {
    throw "Required reusable module not found: $buildCommonModulePath"
}

if (-not (Test-Path -Path $uvCommonModulePath)) {
    throw "Required reusable module not found: $uvCommonModulePath"
}

Import-Module $buildCommonModulePath -Force
Import-Module $uvCommonModulePath -Force

$repoRoot = Resolve-Path (Join-Path $scriptDir "..\..\..")
Set-Location $repoRoot

$script:BuildContext = New-BuildContext -Workspace $repoRoot -LogDir "logs"

function Write-Log { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
function Write-LogWarning { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }

$script:UvCommandRunner = {
    param([string]$File, [string[]]$CommandArgs)
    Invoke-BuildExternal -Context $script:BuildContext -File $File -Parameters $CommandArgs | Out-Null
}

$script:UvLogInfo = { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
$script:UvLogWarning = { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }

Open-BuildLog -Context $script:BuildContext

Write-Log "Using Python version: $PythonVersion for docs build"

$VENV_DIR = Join-Path $repoRoot ".venv-docs"

try {
    if (Test-Path $VENV_DIR) {
        Write-Log "Using existing docs venv at $VENV_DIR"
    } else {
        Write-Log "Creating docs venv at $VENV_DIR"
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

    Write-Log "Looking for coverage HTML in $SRC ..."
    $coverageHtmlDir = Join-Path $SRC "coverage-html-$PythonVersion"
    if (Test-Path $coverageHtmlDir) {
        Copy-Item "$coverageHtmlDir\*" $COVERAGE_DST -Recurse -Force
        Write-Log "Copied $coverageHtmlDir -> $COVERAGE_DST"
    } elseif (Test-Path (Join-Path $SRC "coverage")) {
        Copy-Item "$SRC\coverage\*" $COVERAGE_DST -Recurse -Force
        Write-Log "Copied $SRC\coverage -> $COVERAGE_DST"
    } elseif (Test-Path (Join-Path $SRC "htmlcov")) {
        Copy-Item "$SRC\htmlcov\*" $COVERAGE_DST -Recurse -Force
        Write-Log "Copied $SRC\htmlcov -> $COVERAGE_DST"
    }

    $coverageXml = Join-Path $SRC "coverage-$PythonVersion.xml"
    if (Test-Path $coverageXml) {
        Copy-Item $coverageXml (Join-Path $STATIC_DIR "coverage.xml") -Force
        Write-Log "Copied coverage-$PythonVersion.xml -> coverage.xml"
    } elseif (Test-Path (Join-Path $SRC "coverage.xml")) {
        Copy-Item (Join-Path $SRC "coverage.xml") (Join-Path $STATIC_DIR "coverage.xml") -Force
        Write-Log "Copied coverage.xml"
    }

    Write-Log "Copying pytest HTML reports..."
    Get-ChildItem -Path $SRC -Filter "pytest-report-*.html" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $TEST_RESULTS_DST -Force
        Write-Log "Copied $($_.Name) to $TEST_RESULTS_DST"
    }

    Get-ChildItem -Path $SRC -Filter "report-*.xml" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $TEST_RESULTS_DST -Force
        Write-Log "Copied $($_.Name) to $TEST_RESULTS_DST"
    }

    Get-ChildItem -Path $SRC -Filter "pytest-report-*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName $STATIC_DIR -Force
    }

    Set-Location (Join-Path $repoRoot "docs")
    Invoke-BuildExternal -Context $script:BuildContext -File "make" -Parameters @("html") | Out-Null

    Write-Log "=== Docs build completed ==="

} finally {
    Remove-UvProjectEnvironment -EnvPath $VENV_DIR -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Write-BuildSummary -Context $script:BuildContext
    Close-BuildLog -Context $script:BuildContext
}
