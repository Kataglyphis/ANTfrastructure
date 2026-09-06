# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python static analysis runner for Windows

.DESCRIPTION
    Runs static analysis tools (codespell, bandit, vulture, ruff, ty) on Python code.
    Uses shared modules from ContainerHub.

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

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot

$PackageName = Get-PyprojectPackageName -RepoRoot $repoRoot -Default $PackageName

# #141: shared preamble — context/log/wrappers/uv delegates come from
# New-CiSession (Initialize-CiEnvironment.ps1).
$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates

Write-CiLog "Using Python version: $PythonVersion"
Write-CiLog "Running static analysis for package: $PackageName"

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
            "-x", "tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results"
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

    Write-CiLog "Static analysis completed"

} finally {
    Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Close-BuildLog -Context $script:BuildContext
}
