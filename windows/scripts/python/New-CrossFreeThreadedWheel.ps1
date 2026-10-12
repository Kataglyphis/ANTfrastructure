# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
    A cross lane's cp3XYt wheel: the host's free-threaded interpreter builds it against the image's target tree, gates it statically,
    and packs it with what the device needs to prove it.
.DESCRIPTION
    Invoke-CiPackaging.ps1 runs it as a child process, so the VS cross environment it enters ends with it. The project's setuptools
    build reads DIST_EXTRA_CONFIG: every build_ext instance takes the target platform and libs, the one bdist_wheel reinitializes too.
    See docs/python-ci.md § The arm64 cross lane's free-threaded wheel.
.PARAMETER OutDir
    Receives the wheel and its device kit: the target's free-threaded tree as python\, free-threaded-wheel.py, WindowsPythonWheel.Common.psm1
    and Test-FreeThreadedWheel.ps1, which container-ci-windows.yml's arm64 run job starts.
.PARAMETER Mode
    auto, on or off, as PYTHON_FREE_THREADED_WHEEL.
#>
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Mode = 'auto'
)

$ErrorActionPreference = 'Stop'
foreach ($module in 'WindowsSourceBuild.Common', 'WindowsPythonWheel.Common') {
    Import-Module (Join-Path $PSScriptRoot "..\modules\$module.psm1") -Force -DisableNameChecking
}

$arch = Get-WindowsTargetArch
$tag = Get-PythonWheelTag
$gil = Get-SourceBuildPython
$target = Get-TargetBuildPython -FreeThreaded
$pyproject = Join-Path $RepoRoot 'pyproject.toml'
$plan = Get-FreeThreadedWheelPlan -Mode $Mode -PyprojectPath $pyproject -Python $gil.Exe -CrossArch $arch -TargetLib $target.Lib
Write-Host $plan.Reason
if (-not $plan.Build) { exit 0 }

# As declared, as the native lane's isolated build resolves them.
$requires = @(& $gil.Exe -I -c "import sys, tomllib; print('\n'.join(tomllib.load(open(sys.argv[1], 'rb')).get('build-system', {}).get('requires', [])))" $pyproject |
        Where-Object { $_ })
if ($LASTEXITCODE -ne 0 -or $requires.Count -eq 0) { throw "$pyproject declares no [build-system] requires to build the $tag wheel with" }

Enter-VsDevCmdEnvironment -Arch $arch
$work = [IO.Directory]::CreateTempSubdirectory('ft-cross-').FullName
try {
    $venv = New-FreeThreadedBuildPython -GilPython $gil -VenvDir (Join-Path $work 'venv') -Package $requires
    $cfg = Join-Path $work 'cross.cfg'
    [IO.File]::WriteAllLines($cfg, [string[]]@('[build_ext]', "plat_name = $($tag -replace '_', '-')", "library_dirs = $($target.LibDir)",
            '[bdist_wheel]', "plat_name = $tag"))
    $env:DIST_EXTRA_CONFIG = $cfg
    $env:CYTHONIZE = 'True'
    $dist = Join-Path $work 'dist'
    & uv build --wheel --no-build-isolation --python $venv.Exe --out-dir $dist $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "the $tag free-threaded build failed (exit $LASTEXITCODE)" }
    $wheel = Select-FreeThreadedWheel -Wheels @(Get-ChildItem -LiteralPath $dist -Filter '*.whl' -File) -AbiTag (Get-FreeThreadedAbiTag)
    if (-not $wheel) {
        Write-Host "free-threaded wheel: the build is pure, and the py3-none-any wheel already serves $tag"
        exit 0
    }
    $findings = @(Get-FreeThreadedWheelFinding -Path $wheel.FullName -PlatformTag $tag) + @(Get-FreeThreadedWheelImportFinding -Path $wheel.FullName)
    if ($findings.Count -gt 0) { throw "$($wheel.Name) fails the cp3XYt gates:`n  $($findings -join "`n  ")" }
    Assert-WheelTargetArch -WheelPath $wheel.FullName

    # The device kit: no hub checkout reaches the arm64 run job, only this directory.
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Copy-Item -LiteralPath $wheel.FullName -Destination $OutDir
    Copy-Item -LiteralPath (Split-Path $target.LibDir -Parent) -Destination (Join-Path $OutDir 'python') -Recurse
    foreach ($file in @((Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel.py'),
            (Join-Path $PSScriptRoot '..\modules\WindowsPythonWheel.Common.psm1'), (Join-Path $PSScriptRoot 'Test-FreeThreadedWheel.ps1'))) {
        Copy-Item -LiteralPath $file -Destination $OutDir
    }
    Write-Host "free-threaded wheel: $($wheel.Name) gated for $tag; the device proves it from $OutDir"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
