# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python package builder for Windows

.DESCRIPTION
    Builds source distribution and binary wheels for Python packages.
    Uses shared modules from ANTfrastructure.

.PARAMETER PythonVersion
    Python version to use (default: "3.14")

.PARAMETER RepoRoot
    Root of the repo being built. Default (empty) keeps today's behaviour:
    Initialize-CiEnvironment resolves three levels above this script, i.e. the
    ANTfrastructure checkout itself. A consumer that vendors or submodules
    ANTfrastructure passes ITS OWN root here.

.EXAMPLE
    Invoke-CiPackaging.ps1 -PythonVersion "3.13"
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    # Root of the repo being built. Empty = today's behaviour, where
    # Initialize-CiEnvironment resolves three levels above this script and lands
    # in the ANTfrastructure checkout. A consumer that vendors or submodules
    # ANTfrastructure (<consumer>/third_party/ANTfrastructure/windows/scripts/python)
    # MUST pass its own root, or every path derived below -- pyproject.toml, the
    # venvs, the log dir -- is read from and written into the hub checkout
    # instead of the repo under test.
    [string]$RepoRoot = ''
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
# $RepoRoot and $repoRoot are ONE variable (PowerShell identifiers are
# case-insensitive): the assignment deliberately replaces the caller's raw value
# with the RESOLVED absolute path Initialize-CiEnvironment returns.
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot -RepoRoot $RepoRoot

# #141: shared preamble — context/log/wrappers/uv delegates come from
# New-CiSession (Initialize-CiEnvironment.ps1).
$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates

Write-CiLog "Using Python version: $PythonVersion"

try {
    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (source)" -Script {
        Write-CiLog "=== Packaging (source) ==="
        $envPath = Join-Path $repoRoot ".venv-packaging-sources"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-sources" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("build") | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (Windows binaries)" -Script {
        Write-CiLog "=== Packaging (Windows binaries) ==="
        $env:CYTHONIZE = "True"

        $envPath = Join-Path $repoRoot ".venv-packaging-binaries"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-binaries" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @("build") | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    Write-CiLog "=== Packaging completed ==="

} finally {
    Write-BuildSummary -Context $script:BuildContext
    Close-BuildLog -Context $script:BuildContext

    if ($script:BuildContext.Results.Failed.Count -gt 0) {
        exit 1
    }
}

