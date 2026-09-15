# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python static analysis runner for Windows

.DESCRIPTION
    Runs static analysis tools (codespell, bandit, vulture, ruff, ty) on Python code.
    Uses shared modules from ANTfrastructure.

.PARAMETER PythonVersion
    Python version to use (default: "3.14")

.PARAMETER PackageName
    Name of the package to analyze (derived from pyproject.toml if not specified)

.PARAMETER RepoRoot
    Root of the repo being built. Default (empty) keeps today's behaviour:
    Initialize-CiEnvironment resolves three levels above this script, i.e. the
    ANTfrastructure checkout itself. A consumer that vendors or submodules
    ANTfrastructure passes ITS OWN root here.

.PARAMETER ExtraPaths
    Extra paths to analyse, relative to the repo root. A consumer whose package
    is not the whole first-party tree names the rest here; bandit gets each as
    its own -r target. The Linux twin's knob is STATIC_ANALYSIS_EXTRA_PATHS.

.EXAMPLE
    Invoke-CiStaticAnalysis.ps1 -PackageName "my_package"
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    [string]$PackageName = "",
    # Root of the repo being built. Empty = today's behaviour, where
    # Initialize-CiEnvironment resolves three levels above this script and lands
    # in the ANTfrastructure checkout. A consumer that vendors or submodules
    # ANTfrastructure (<consumer>/third_party/ANTfrastructure/windows/scripts/python)
    # MUST pass its own root, or every path derived below -- pyproject.toml, the
    # venvs, the log dir -- is read from and written into the hub checkout
    # instead of the repo under test.
    [string]$RepoRoot = '',
    # Extra first-party paths to analyse, relative to the repo root. Empty keeps
    # today's behaviour. Same knob as the Linux twin's STATIC_ANALYSIS_EXTRA_PATHS.
    [string[]]$ExtraPaths = @()
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
# $RepoRoot and $repoRoot are ONE variable (PowerShell identifiers are
# case-insensitive): the assignment deliberately replaces the caller's raw value
# with the RESOLVED absolute path Initialize-CiEnvironment returns.
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot -RepoRoot $RepoRoot

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

    $analysisPaths = @($PackageName, "tests", "docs/source/conf.py", "setup.py", "README.md") + $ExtraPaths
    # bandit takes -r per target rather than a path list, so the extras are
    # spelled separately below. $analysisPaths[0..3] indexing is gone with them:
    # the non-README slice is now named, or appending would silently drop every
    # extra path past the fourth element.
    $codeOnlyPaths = @($PackageName, "tests", "docs/source/conf.py", "setup.py") + $ExtraPaths
    $banditExtra = @($ExtraPaths | ForEach-Object { "-r"; $_ })

    # One owner for the uv-run-an-analyser shape. Every analyser below
    # differs only in tool name, flags and whether it takes the path list;
    # the shape lives here once instead of at every call site.
    #
    # Invoke-BuildGate, NOT Invoke-BuildOptional. WindowsBuild.Common's own
    # docstring calls Optional "the exact inverse": it records a failure and
    # carries on, and nothing re-raises it -- so this file was a gate in name
    # only. Gate records the failure too, and Assert-BuildGates at the bottom
    # turns the batch into one error. Its Linux twin
    # (02-toolchain/python/ci_static_analysis.sh) has run this way since it was
    # corrected for the same defect.
    $runAnalyser = {
        param([string]$Name, [string[]]$Argv, [string[]]$Targets)
        Invoke-BuildGate -Context $script:BuildContext -Name $Name -Script {
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" `
                -Parameters (@("run", "--active") + $Argv + $Targets) | Out-Null
        }.GetNewClosure()
    }
    & $runAnalyser "codespell"   @("codespell")               $analysisPaths

    & $runAnalyser "bandit" (@(
        "bandit", "-r", $PackageName
    ) + $banditExtra + @(
        "-x", "tests,.venv,.venv_static_analysis,ExternalLib,third_party,archive,docs/test_results"
    )) @()

    & $runAnalyser "vulture"     @("vulture")                 $codeOnlyPaths
    # --no-fix and --check --diff, not --fix and a bare format: a gate judges the
    # tree as COMMITTED. Rewriting it makes the step pass and leaves the change in
    # a CI checkout nobody sees. Same wording, same reason, as the Linux twin.
    & $runAnalyser "ruff check"  @("ruff", "check", "--no-fix")          $codeOnlyPaths
    & $runAnalyser "ruff format" @("ruff", "format", "--check", "--diff") $codeOnlyPaths

    & $runAnalyser "ty"          @("ty", "check")             @()

    # The whole point of the change above: without this, every failure recorded
    # by Invoke-BuildGate stays recorded and the script still exits 0. It also
    # refuses to report green when no gate ran at all.
    Assert-BuildGates -Context $script:BuildContext -Label 'python static analysis'

    Write-CiLog "Static analysis completed"

} finally {
    Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Close-BuildLog -Context $script:BuildContext
}
