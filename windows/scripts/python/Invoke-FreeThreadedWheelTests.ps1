#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Runs a project's tests on its installed cp3XYt wheel after Invoke-CiPackaging.ps1: the Windows twin of test-free-threaded-wheel.sh.
.DESCRIPTION
    A fresh venv of the image's free-threaded interpreter gets the lock's set, then dist\'s cp3XYt wheel with --no-deps.
    pyproject.toml's [tool.antfrastructure.free-threaded-wheel-tests] names the tests, which run outside the checkout through the shared
    free-threaded-wheel-tests.py; it fails when the GIL is on afterwards. See docs/python-ci.md#the-suite-on-the-installed-wheel
.PARAMETER PythonVersion
    The packaging X.Y; empty takes the pin.
.PARAMETER FreeThreadedWheel
    auto, on or off, as Invoke-CiPackaging.ps1 takes it; empty takes PYTHON_FREE_THREADED_WHEEL, else auto.
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = '',
    [string]$RepoRoot = '',
    [string]$TargetArch = '',
    [string]$FreeThreadedWheel = ''
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -EnterRepoRoot -RepoRoot $RepoRoot -Modules @(
    'WindowsScripts.Shared', 'WindowsBuild.Common', 'WindowsUv.Common', 'WindowsTargetArch.Common', 'WindowsPythonWheel.Common', 'WindowsPythonWheel.Suite')
if (-not $PythonVersion) { $PythonVersion = (Get-PinnedPythonVersion).MajorMinor }
$arch = Get-WindowsTargetArch -Arch $TargetArch
$ftMode = Resolve-FreeThreadedWheelMode -Value $FreeThreadedWheel
$ft = Get-FreeThreadedTarget -PythonVersion $PythonVersion
$pyproject = Join-Path $repoRoot 'pyproject.toml'
$context = New-CiSession -RepoRoot $repoRoot -WithUvDelegates

function Get-WheelTestsPlan {
    <#
    .SYNOPSIS
        The suite and the dist\ wheel to test, or Skip: why this run tests none, in the cases where Invoke-CiPackaging.ps1 builds no native twin.
    #>
    if (Test-WindowsCrossTarget -Arch $arch) { return @{ Skip = "the $arch cross build's wheel is tested on the device" } }
    $gilPython = if ($ftMode -ceq 'off') { '' } else { Find-UvPython -Request (Get-UvPythonRequest -Version $PythonVersion) }
    $build = Get-FreeThreadedWheelPlan -Mode $ftMode -PyprojectPath $pyproject -Python $gilPython
    if (-not $build.Build) { return @{ Skip = $build.Reason -replace '^free-threaded wheel skipped: ', '' } }
    $suite = Get-FreeThreadedWheelSuite -Python $gilPython -PyprojectPath $pyproject
    if (-not $suite) { return @{ Skip = 'pyproject.toml has no [tool.antfrastructure.free-threaded-wheel-tests]' } }
    $platform = Get-PythonWheelTag -Arch $arch
    $dist = Join-Path $repoRoot 'dist'
    $wheels = @(Get-ChildItem -LiteralPath $dist -Filter "*-$($ft.AbiTag)-$platform.whl" -File -ErrorAction SilentlyContinue)
    if ($wheels.Count -ne 1) {
        $built = @(Get-ChildItem -LiteralPath $dist -File -ErrorAction SilentlyContinue).Name -join ' '
        throw "expected one $($ft.AbiTag) $platform wheel in dist\, found $($wheels.Count) among: $built"
    }
    return @{ Suite = $suite; Wheel = $wheels[0] }
}

function Install-WheelTestsVenv([string]$Work, [pscustomobject]$Suite, [IO.FileInfo]$Wheel) {
    # A fresh venv of the image's free-threaded interpreter, found and never downloaded: the lock's set, then the wheel alone.
    $interpreter = Find-UvPython -Request $ft.Version -Hint "the image ships python$($ft.Version).exe"
    $venv = Join-Path $Work 'venv'
    $python = Join-Path $venv 'Scripts\python.exe'
    $requirements = Join-Path $Work 'requirements.txt'
    $export = @('export', '--locked', '--no-emit-project') + @(if ($Suite.Extra) { '--extra', $Suite.Extra }) + @('--format', 'requirements.txt', '-o', $requirements)
    foreach ($uvArgs in @(@('venv', '--python', $interpreter, $venv), $export, @('pip', 'install', '--python', $python, '-r', $requirements),
            @('pip', 'install', '--python', $python, '--no-deps', $Wheel.FullName))) {
        Invoke-BuildExternal -Context $context -File 'uv' -Parameters $uvArgs | Out-Null
    }
    return $python
}

function Invoke-WheelTestsRun([string]$Python, [string]$RunDir, [pscustomobject]$Suite) {
    # The table's env reaches this one pytest process and the processes it starts, not the rest of the driver.
    $pytest = @(if ($Suite.Isolated) { '-I' }) + @((Get-FreeThreadedWheelSuiteHelper), 'run', '--') + $Suite.PytestArgs
    Push-Location -LiteralPath $RunDir
    try {
        return Invoke-WithProcessEnvironment -Environment $Suite.Env -ScriptBlock {
            Invoke-BuildExternal -Context $context -File $Python -Parameters $pytest -IgnoreExitCode
        }
    } finally {
        Pop-Location
    }
}

try {
    Invoke-BuildStep -Context $context -StepName 'Free-threaded wheel tests' -Critical -Script {
        $plan = Get-WheelTestsPlan
        if ($plan['Skip']) {
            Write-CiLog "free-threaded wheel tests skipped: $($plan.Skip)"
            return
        }
        # Container-local: on the workspace's bind mount uv cannot rename its temporary files into place.
        $work = [IO.Directory]::CreateTempSubdirectory('ft-wheel-tests-').FullName
        try {
            $python = Install-WheelTestsVenv -Work $work -Suite $plan.Suite -Wheel $plan.Wheel
            Copy-FreeThreadedWheelTestFile -Suite $plan.Suite -RepoRoot $repoRoot -Destination (Join-Path $work 'run')
            Write-CiLog "free-threaded wheel tests: $($plan.Wheel.Name) on $(& $python -VV)"
            $code = Invoke-WheelTestsRun -Python $python -RunDir (Join-Path $work 'run') -Suite $plan.Suite
            if ($code -ne 0) { throw "the tests failed against $($plan.Wheel.Name), or left the GIL enabled (exit $code)" }
            Write-CiLog "free-threaded wheel tests passed: $($plan.Wheel.Name)"
        } finally {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    } | Out-Null
} finally {
    if (Complete-CiBuildSession -Context $context) { exit 1 }
}
