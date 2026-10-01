# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Runs the Python static-analysis gates (codespell, bandit, vulture, ruff, ty) on Windows.
.PARAMETER PythonVersion
    Python version to use.
.PARAMETER PackageName
    Package to analyse; derived from pyproject.toml when empty.
.PARAMETER RepoRoot
    Root of the repo being built; empty means the ANTfrastructure checkout, so a consumer must pass its own.
.PARAMETER ExtraPaths
    Extra first-party paths relative to the repo root (the Linux twin's STATIC_ANALYSIS_EXTRA_PATHS).
.PARAMETER BanditExcludes
    bandit's -x list as one comma-separated string; replaces the default (the Linux twin's BANDIT_EXCLUDES).
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    [string]$PackageName = "",
    [string]$RepoRoot = '',
    [string[]]$ExtraPaths = @(),
    # Must equal the Linux twin's BANDIT_EXCLUDES default character for character.
    [string]$BanditExcludes = 'tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results'
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
# $RepoRoot and $repoRoot are one variable: this deliberately replaces the raw value with the resolved path.
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot -RepoRoot $RepoRoot

$PackageName = Get-PyprojectPackageName -RepoRoot $repoRoot -Default $PackageName

$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates

Write-CiLog "Using Python version: $PythonVersion"
Write-CiLog "Running static analysis for package: $PackageName"

$envPath = Join-Path $repoRoot ".venv-static-analysis"

try {
    New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-static-analysis" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

    Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython

    $analysisPaths = @($PackageName, "tests", "docs/source/conf.py", "setup.py", "README.md") + $ExtraPaths
    # Named, not an index slice, so appended extra paths are never dropped.
    $codeOnlyPaths = @($PackageName, "tests", "docs/source/conf.py", "setup.py") + $ExtraPaths
    # One -r, then every target: bandit's -r is a flag, and a second one is "unrecognized arguments".
    $banditTargets = @($PackageName) + $ExtraPaths

    # Invoke-BuildGate, not Invoke-BuildOptional: Optional records a failure and carries on, so nothing would gate.
    $runAnalyser = {
        param([string]$Name, [string[]]$Argv, [string[]]$Targets)
        # A local, not $script: -- inside GetNewClosure's module $script:BuildContext is $null, which failed all six gates.
        $context = $script:BuildContext
        Invoke-BuildGate -Context $context -Name $Name -Script {
            Invoke-BuildExternal -Context $context -File "uv" `
                -Parameters (@("run", "--active") + $Argv + $Targets) | Out-Null
        }.GetNewClosure()
    }
    & $runAnalyser "codespell"   @("codespell")               $analysisPaths

    & $runAnalyser "bandit" (@(
        "bandit", "-r"
    ) + $banditTargets + @(
        "-x", $BanditExcludes
    )) @()

    & $runAnalyser "vulture"     @("vulture")                 $codeOnlyPaths
    # --no-fix and --check: a gate judges the tree as committed, not a rewritten CI checkout.
    & $runAnalyser "ruff check"  @("ruff", "check", "--no-fix")          $codeOnlyPaths
    & $runAnalyser "ruff format" @("ruff", "format", "--check", "--diff") $codeOnlyPaths

    & $runAnalyser "ty"          @("ty", "check")             @()

    # Without this a recorded gate failure still exits 0; it also refuses green when no gate ran.
    Assert-BuildGates -Context $script:BuildContext -Label 'python static analysis'

    Write-CiLog "Static analysis completed"

} finally {
    Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Close-BuildLog -Context $script:BuildContext
}
