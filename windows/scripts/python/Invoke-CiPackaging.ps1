# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    Builds the sdist and the Windows wheels of a Python package, the binary one twice when the project declares free-threading.
.PARAMETER PythonVersion
    Python version to use.
.PARAMETER RepoRoot
    Root of the repo being built; empty means the ANTfrastructure checkout, so a consumer must pass its own.
.PARAMETER TargetArch
    amd64 or arm64; empty takes the image's WINDOWS_TARGET_ARCH. arm64 builds no Cython wheel and lays the app out in
    dist\windows-arm64 (bundle, packages), where the arm64 lane picks it up.
.PARAMETER FreeThreadedWheel
    auto, on or off; empty takes PYTHON_FREE_THREADED_WHEEL, else auto (docs/python-ci.md § Two wheels: GIL and free-threaded).
#>

[CmdletBinding()]
Param(
    [string]$PythonVersion = "3.14",
    [string]$RepoRoot = '',
    [string]$TargetArch = '',
    [string]$FreeThreadedWheel = ''
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
# $RepoRoot and $repoRoot are one variable: this deliberately replaces the raw value with the resolved path.
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsUv.Common', 'WindowsTargetArch.Common', 'WindowsPythonWheel.Common') -EnterRepoRoot -RepoRoot $RepoRoot
$arch = Get-WindowsTargetArch -Arch $TargetArch
$cross = Test-WindowsCrossTarget -Arch $arch
$ftMode = Resolve-FreeThreadedWheelMode -Value $FreeThreadedWheel

$script:BuildContext = New-CiSession -RepoRoot $repoRoot -WithUvDelegates
# uv build picks its own interpreter, not the venv's: a plain 3.14 built OrchestrANT's wheel as cp314t.
$pythonRequest = Get-UvPythonRequest -Version $PythonVersion
$buildArgs = @('build', '--python', $pythonRequest)

Write-CiLog "Using Python version: $PythonVersion"

try {
    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (source)" -Script {
        Write-CiLog "=== Packaging (source) ==="
        # A cross lane ships only the pure wheel; installing the host's dependency set is the native lane's work.
        if ($cross) {
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $buildArgs | Out-Null
            return
        }
        $envPath = Join-Path $repoRoot ".venv-packaging-sources"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-sources" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null

        try {
            Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $buildArgs | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    # Cython here compiles for the host; a cross bundle takes the pure wheel instead (Select-PythonAppWheel).
    if (-not $cross) { Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (Windows binaries)" -Script {
        Write-CiLog "=== Packaging (Windows binaries) ==="
        $env:CYTHONIZE = "True"

        $envPath = Join-Path $repoRoot ".venv-packaging-binaries"
        New-UvProjectEnvironment -Workspace $repoRoot -PythonVersion $PythonVersion -EnvName ".venv-packaging-binaries" -CommandRunner $script:UvCommandRunner -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning | Out-Null
        # The venv's base interpreter, which the venv step installs when the host lacks it.
        $homeLine = @(Get-Content -LiteralPath (Join-Path $envPath 'pyvenv.cfg') | Where-Object { $_ -match '^home\s*=' })
        if ($homeLine.Count -ne 1) { throw "$envPath\pyvenv.cfg names no single home interpreter" }
        Add-PythonLibPath -PythonDir ($homeLine[0] -replace '^home\s*=\s*', '').Trim()

        try {
            Sync-UvProjectDependencies
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters $buildArgs | Out-Null
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null }

    # The binary build again on the image's free-threaded interpreter, then a fresh venv of it must load the wheel GIL-free.
    Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (free-threaded binaries)" -Script {
        $gilPython = if ($cross -or $ftMode -ceq 'off') { '' } else { Find-UvPython -Request $pythonRequest }
        $plan = Get-FreeThreadedWheelPlan -Mode $ftMode -PyprojectPath (Join-Path $repoRoot 'pyproject.toml') -Python $gilPython -CrossArch $(if ($cross) { $arch } else { '' })
        Write-CiLog $plan.Reason
        if (-not $plan.Build) { return }
        $ft = Get-FreeThreadedTarget -PythonVersion $PythonVersion
        $ftPython = Find-UvPython -Request $ft.Version -Hint "the image ships python$($ft.Version).exe; -FreeThreadedWheel off skips it"
        Write-CiLog "free-threaded wheel: building with $ftPython"
        $env:CYTHONIZE = "True"
        Add-PythonLibPath -PythonDir (Split-Path -Parent $ftPython)
        $out = Join-Path $repoRoot 'build\free-threaded-dist'
        Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @('build', '--python', $ftPython, '--out-dir', $out) | Out-Null
        $wheel = Select-FreeThreadedWheel -Wheels @(Get-ChildItem -LiteralPath $out -Filter '*.whl' -File) -AbiTag $ft.AbiTag
        if (-not $wheel) {
            Write-CiLog "free-threaded wheel: the build is pure, and the py3-none-any wheel already serves $($ft.Version)"
            return
        }
        $shipped = Join-Path $repoRoot "dist\$($wheel.Name)"
        Move-Item -LiteralPath $wheel.FullName -Destination $shipped -Force
        $envPath = Join-Path $repoRoot ".venv-packaging-free-threaded"
        try {
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @('venv', '--python', $ftPython, '--clear', $envPath) | Out-Null
            $venvPython = Join-Path $envPath 'Scripts\python.exe'
            Invoke-BuildExternal -Context $script:BuildContext -File "uv" -Parameters @('pip', 'install', '--python', $venvPython, '--no-deps', $shipped) | Out-Null
            Write-CiLog "free-threaded proof: $(Invoke-FreeThreadedWheelProof -Python $venvPython -Distribution ($wheel.Name -split '-')[0])"
        } finally {
            Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
        }
    } | Out-Null

    # packaging/app.json opts a consumer in: the app bundle, then its packages, each started once (docs/python-app-bundles.md § Packages).
    if (Test-Path -LiteralPath (Join-Path $repoRoot 'packaging\app.json') -PathType Leaf) {
        Invoke-BuildStep -Context $script:BuildContext -StepName "Packaging (app bundle + installers)" -Script {
            $laneDir = Join-Path $repoRoot "dist\windows-$(Get-WindowsPackageArch -Arch $arch)"
            $bundle = if ($cross) { Join-Path $laneDir 'bundle' } else { Join-Path $repoRoot 'build\app-bundle' }
            $packages = if ($cross) { Join-Path $laneDir 'packages' } else { Join-Path $repoRoot 'dist\packages' }
            Invoke-BuildExternal -Context $script:BuildContext -File 'pwsh' -Parameters @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'New-PythonAppBundle.ps1'),
                '-RepoRoot', $repoRoot, '-WheelDir', 'dist', '-OutDir', $bundle, '-TargetArch', $arch) | Out-Null
            Invoke-BuildExternal -Context $script:BuildContext -File 'pwsh' -Parameters @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'New-PythonAppPackage.ps1'),
                '-RepoRoot', $repoRoot, '-Bundle', $bundle, '-OutDir', $packages) | Out-Null
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

