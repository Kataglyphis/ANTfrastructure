<#
.SYNOPSIS
    Generic Python static analysis runner for Windows

.DESCRIPTION
    Runs static analysis tools (codespell, bandit, vulture, ruff, ty) on Python code.
    Uses shared modules from Kataglyphis-ContainerHub.

.PARAMETER PythonVersion
    Python version to use (default: "3.14")

.PARAMETER PackageName
    Name of the package to analyze (derived from pyproject.toml if not specified)

.EXAMPLE
    Invoke-CiStaticAnalysis.ps1 -PackageName "my_package"
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    [string]$PackageName = ""
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

if ([string]::IsNullOrEmpty($PackageName)) {
    if (Test-Path (Join-Path $repoRoot "pyproject.toml")) {
        $pyprojectContent = Get-Content (Join-Path $repoRoot "pyproject.toml") -Raw
        if ($pyprojectContent -match 'name\s*=\s*"([^"]+)"') {
            $PackageName = $Matches[1]
        }
    }
    if ([string]::IsNullOrEmpty($PackageName)) {
        $PackageName = Split-Path $repoRoot -Leaf
    }
}

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

Write-Log "Using Python version: $PythonVersion"
Write-Log "Running static analysis for package: $PackageName"

$envPath = Join-Path $repoRoot ".venv-static-analysis"

try {
    New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-static-analysis" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

    Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython

    $analysisPaths = @($PackageName, "tests", "docs/source/conf.py", "setup.py", "README.md")

    Invoke-BuildOptional -Context $script:BuildContext -Name "codespell" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("run", "--active", "codespell") + $analysisPaths | Out-Null
    }

    Invoke-BuildOptional -Context $script:BuildContext -Name "bandit" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @(
            "run", "--active", "bandit", "-r", $PackageName,
            "-x", "tests,.venv,.venv_static_analysis,ExternalLib,archive,docs/test_results"
        ) | Out-Null
    }

    Invoke-BuildOptional -Context $script:BuildContext -Name "vulture" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @(
            "run", "--active", "vulture"
        ) + $analysisPaths[0..3] | Out-Null
    }

    Invoke-BuildOptional -Context $script:BuildContext -Name "ruff check" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @(
            "run", "--active", "ruff", "check", "--fix"
        ) + $analysisPaths[0..3] | Out-Null
    }

    Invoke-BuildOptional -Context $script:BuildContext -Name "ruff format" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @(
            "run", "--active", "ruff", "format"
        ) + $analysisPaths[0..3] | Out-Null
    }

    Invoke-BuildOptional -Context $script:BuildContext -Name "ty" -Script {
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("run", "--active", "ty", "check") | Out-Null
    }

    Write-Log "Static analysis completed"

} finally {
    Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Close-BuildLog -Context $script:BuildContext
}