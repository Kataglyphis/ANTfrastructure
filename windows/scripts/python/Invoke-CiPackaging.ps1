# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds the sdist and the Windows wheels of a Python package.
.PARAMETER PythonVersion
    Python version to use.
.PARAMETER RepoRoot
    Root of the repo being built; empty means the ANTfrastructure checkout, so a consumer must pass its own.
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    [string]$RepoRoot = ''
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
# $RepoRoot and $repoRoot are one variable: this deliberately replaces the raw value with the resolved path.
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common') -EnterRepoRoot -RepoRoot $RepoRoot

$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates
# uv build picks its own interpreter, not the venv's: a plain 3.14 built OrchestrANT's wheel as cp314t.
$pythonRequest = Get-UvPythonRequest -Version $PythonVersion
$buildArgs = @('build', '--python', $pythonRequest)

Write-CiLog "Using Python version: $PythonVersion"

try {
    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (source)" -Script {
        Write-CiLog "=== Packaging (source) ==="
        $envPath = Join-Path $repoRoot ".venv-packaging-sources"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-sources" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $buildArgs | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (Windows binaries)" -Script {
        Write-CiLog "=== Packaging (Windows binaries) ==="
        $env:CYTHONIZE = "True"
        $pythonExe = "$(& uv python find $pythonRequest)".Trim()
        if ($LASTEXITCODE -ne 0 -or -not $pythonExe) { throw "uv python find $pythonRequest failed (exit $LASTEXITCODE)" }
        $pythonDir = Split-Path -Parent $pythonExe
        # The image's CPython is an in-tree build: python3XY.lib sits beside python.exe, where setuptools never looks (LNK1104).
        if (Get-ChildItem -LiteralPath $pythonDir -Filter 'python3*.lib' -File) { $env:LIB = "$pythonDir;$env:LIB" }

        $envPath = Join-Path $repoRoot ".venv-packaging-binaries"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-binaries" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $buildArgs | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    # packaging/app.json opts a consumer in: the app bundle, then its packages, each started once (docs/python-app-bundles.md § Packages).
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'packaging\app.json') -PathType Leaf) {
        Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (app bundle + installers)" -Script {
            $bundle = Join-Path $repoRoot 'build\app-bundle'
            Invoke-BuildExternal -Context $script:BuildContext -File 'pwsh' -Parameters @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'New-PythonAppBundle.ps1'),
                '-RepoRoot', $repoRoot, '-WheelDir', 'dist', '-OutDir', $bundle) | Out-Null
            Invoke-BuildExternal -Context $script:BuildContext -File 'pwsh' -Parameters @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'New-PythonAppPackage.ps1'),
                '-RepoRoot', $repoRoot, '-Bundle', $bundle, '-OutDir', (Join-Path $repoRoot 'dist\packages')) | Out-Null
        } | Out-Null
    }

    Write-CiLog "=== Packaging completed ==="

} finally {
    Write-BuildSummary -Context $script:BuildContext
    Close-BuildLog -Context $script:BuildContext

    if ($script:BuildContext.Results.Failed.Count -gt 0) {
        exit 1
    }
}

