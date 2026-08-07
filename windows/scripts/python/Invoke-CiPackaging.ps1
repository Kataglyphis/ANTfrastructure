# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Generic Python package builder for Windows

.DESCRIPTION
    Builds source distribution and binary wheels for Python packages.
    Uses shared modules from Kataglyphis-ContainerHub.

.PARAMETER PythonVersion
    Python version to use (default: "3.14")

.EXAMPLE
    Invoke-CiPackaging.ps1 -PythonVersion "3.13"
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot

$script:BuildContext = New-BuildContext -Workspace $repoRoot -LogDir "logs"

function Write-CiLog { param([string]$Message); Write-BuildLog -Context $script:BuildContext -Message $Message }
function Write-CiLogWarning { param([string]$Message); Write-BuildLogWarning -Context $script:BuildContext -Message $Message }

$uvDelegates = New-UvBuildDelegates -Context $script:BuildContext
$script:UvCommandRunner = $uvDelegates.CommandRunner
$script:UvLogInfo = $uvDelegates.LogInfo
$script:UvLogWarning = $uvDelegates.LogWarning

Open-BuildLog -Context $script:BuildContext

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

