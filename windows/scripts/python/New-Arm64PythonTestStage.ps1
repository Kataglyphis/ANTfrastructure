#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    In :winarm64, stages a Python project's pytest legs for windows-11-arm, which then installs nothing (python-ci-windows.yml).
.DESCRIPTION
    Per leg (X.Y, X.Yt): the image's target interpreter; the project's win_arm64 wheel, cross-built with the image's VS and clang-cl; the
    lock's set for the leg's extras and that wheel in the interpreter's site-packages; the wheel alone for the load proof; the leg's run
    and proof scripts; on an X.Yt leg, pyproject.toml's free-threaded wheel tests. Then the test files, Invoke-StagedTests.ps1 and its
    tests.json. See docs/python-ci.md § Windows arm64: the staged test job.
.PARAMETER TestFiles
    Paths, relative to -RepoRoot, staged as the tests' working directory; empty takes tests\ and the pytest configuration files the root has.
.PARAMETER TestEnv
    NAME=value pairs set for each pytest run.
.PARAMETER BuildWheelsInto
    Internal: the child process that builds the legs' wheels in VS's cross environment, which ends with it.
#>
[CmdletBinding()]
param(
    [string]$PythonVersions = "$env:PY_VERSIONS",
    [string]$RepoRoot = (Get-Location).Path,
    [string]$OutDir = 'dist\windows-arm64-python',
    [string]$Extras = "$env:PY_EXTRAS",
    [string]$FreeThreadedExtras = "$env:FT_EXTRAS",
    [string]$TestPaths = "$env:TEST_PATHS",
    [string]$TestFiles = "$env:TEST_FILES",
    [string]$TestEnv = "$env:TEST_ENV",
    # More directories of cp3XYt wheels PyPI lacks; the image's free-threaded deps\ always counts.
    [string[]]$Store = @(),
    [string]$TargetPython = 'C:\runtime\python',
    [string]$TargetFreeThreadedPython = 'C:\runtime\python-freethreaded',
    [string]$BuildWheelsInto = ''
)

$ErrorActionPreference = 'Stop'
foreach ($m in 'WindowsSourceBuild.Common', 'WindowsPythonWheel.Common', 'WindowsPythonApp.Common', 'WindowsPythonWheel.Suite') {
    Import-Module (Join-Path $PSScriptRoot "..\modules\$m.psm1") -DisableNameChecking
}

# The leg's wheel ABI tag: 3.15 is cp315, 3.15t cp315t.
function Get-StageAbiTag([string]$Leg) { return 'cp' + ($Leg -replace '\.|t$', '') + $(if ($Leg.EndsWith('t')) { 't' }) }

function Get-StageTestFile {
    <#
    .SYNOPSIS
        -TestFiles, else tests\ and whichever pytest configuration files -RepoRoot has.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RepoRoot, [string]$TestFiles = '')
    $listed = @(Split-PythonCiList -Value $TestFiles)
    if ($listed.Count -gt 0) { return [string[]]$listed }
    return [string[]]@('tests', 'pytest.ini', 'pyproject.toml', 'setup.cfg', 'tox.ini', 'conftest.py' | Where-Object { Test-Path -LiteralPath (Join-Path $RepoRoot $_) })
}

function New-StageLegScript {
    <#
    .SYNOPSIS
        A leg's two cmd scripts as lines: Run (pytest in run\ with -TestEnv), and Proof (the wheel alone, free-threaded-wheel.py -Check).
    #>
    param(
        [Parameter(Mandatory)][string]$Leg,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Distribution,
        [ValidateSet('load', 'prove')][string]$Check = 'load',
        [string[]]$TestEnv = @(),
        [string[]]$TestPaths = @()
    )
    $bad = @($TestEnv | Where-Object { $_ -notmatch '^[A-Za-z_][A-Za-z0-9_]*=[^"%^&|<>]*$' })
    if ($bad.Count -gt 0) { throw "TestEnv takes NAME=value pairs without quotes or cmd metacharacters, not: $($bad -join ' ')" }
    $python = """%~dp0python-$Leg\$Exe"""
    return [pscustomobject]@{
        Run   = @('@echo off', 'cd /d "%~dp0run"') + @($TestEnv | ForEach-Object { "set ""$_""" }) + @("$python -m pytest -p no:cacheprovider $($TestPaths -join ' ')".TrimEnd())
        # -S keeps the leg's site-packages, which hold the wheel's dependencies, off sys.path.
        Proof = @('@echo off', "set ""PYTHONPATH=%~dp0proof-$Leg""", "$python -S ""%~dp0free-threaded-wheel.py"" $Check $Distribution")
    }
}

$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not (Test-WindowsCrossTarget)) { throw 'New-Arm64PythonTestStage.ps1 runs in :winarm64, whose target interpreters it stages' }
$gil = Get-SourceBuildPython
$pyproject = Join-Path $repo 'pyproject.toml'
$legs = @(Resolve-PythonLegList -PythonVersions $PythonVersions -PyprojectPath $pyproject -Python $gil.Exe)
$work = [IO.Directory]::CreateTempSubdirectory('arm64-stage-').FullName

if ($BuildWheelsInto) {
    Enter-VsDevCmdEnvironment -Arch (Get-WindowsTargetArch)
    # clang-cl reads CL as cl.exe does, so a setup.py that swaps in clang-cl compiles for the target without naming it.
    $env:CL = "--target=$((Get-WindowsTargetArchInfo).ClangTriple)"
    $env:CYTHONIZE = 'True'
    $requires = (Get-PyprojectBuildInfo -Python $gil.Exe -PyprojectPath $pyproject).Requires
    Initialize-PythonAppDirectory -Path $BuildWheelsInto
    foreach ($leg in $legs) {
        $ft = $leg.EndsWith('t')
        $build = Join-Path $work "build-$leg"
        $libDir = Join-Path $(if ($ft) { $TargetFreeThreadedPython } else { $TargetPython }) 'libs'
        $venv = New-CrossBuildPython -GilPython $gil -VenvDir (Join-Path $build 'venv') -Package $requires -FreeThreaded:$ft -LibDir $libDir
        $wheel = Invoke-CrossWheelBuild -Python $venv.Exe -Source $repo -LibDir $libDir -AbiTag (Get-StageAbiTag $leg) -WorkDir $build
        if (-not $wheel) { $wheel = Get-ChildItem -LiteralPath (Join-Path $build 'dist') -Filter '*-none-any.whl' -File | Select-Object -First 1 }
        Copy-Item -LiteralPath $wheel.FullName -Destination $BuildWheelsInto -Force
        Write-Host "Python ${leg}: $($wheel.Name)"
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

$dest = if ([IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repo $OutDir }
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
# Built container-local and copied at the end: on a bind mount uv cannot rename its temporary files into place (os error 3).
$out = Join-Path $work 'stage'
$wheels = Join-Path $out 'wheels'
& pwsh -NoProfile -File $PSCommandPath -RepoRoot $repo -PythonVersions ($legs -join ' ') -BuildWheelsInto $wheels `
    -TargetPython $TargetPython -TargetFreeThreadedPython $TargetFreeThreadedPython
if ($LASTEXITCODE -ne 0) { throw "building the legs' wheels failed (exit $LASTEXITCODE)" }

$distribution = (Get-PyprojectBuildInfo -Python $gil.Exe -PyprojectPath $pyproject).Name
$suite = Get-FreeThreadedWheelSuite -Python $gil.Exe -PyprojectPath $pyproject
$platform = Get-ClangTargetTriple -Arch (Get-WindowsTargetArch)
$manifest = [Collections.Generic.List[object]]::new()

function Initialize-Arm64StageLegPython {
    param([string]$leg, [bool]$ft)
    $pyDir = Join-Path $out "python-$leg"
    Copy-Item -LiteralPath $(if ($ft) { $TargetFreeThreadedPython } else { $TargetPython }) -Destination $pyDir -Recurse
    $site = Join-Path $pyDir 'Lib\site-packages'
    # A leg starts from its lock alone, not from the image's own packages.
    Get-ChildItem -LiteralPath $site -Force | Where-Object Name -ne 'README.txt' | Remove-Item -Recurse -Force
    $exe = @(Get-ChildItem -LiteralPath $pyDir -File -Filter $(if ($ft) { 'python3.*t.exe' } else { 'python.exe' }))
    if ($exe.Count -ne 1) { throw "the target interpreter for $leg holds $($exe.Count) matching executables, not one" }
    return [pscustomobject]@{ Site = $site; Exe = $exe }
}

function Install-Arm64StageLegSite {
    param([string]$leg, [bool]$ft, [string]$abi, [string]$site, $wheel)
    $hostPython = Get-SourceBuildHostPythonExe -GilPython $gil -FreeThreaded:$ft
    $legExtras = @(Split-PythonCiList -Value $(if ($ft -and $FreeThreadedExtras) { $FreeThreadedExtras } else { $Extras }))
    $legWork = Join-Path $work "site-$leg"
    Initialize-PythonAppDirectory -Path $legWork
    $stores = @(if ($ft) { Join-Path (Get-FreeThreadedWheelStore) 'deps' }) + $Store
    Install-PythonCrossSite -HostPython $hostPython -SitePackages $site -RepoRoot $repo -Wheel $wheel.FullName -Extras $legExtras -AllExtras:($legExtras.Count -eq 0) `
        -WorkDir $legWork -Platform $platform -PythonVersion ($leg -replace 't$', '') -Store $stores -StoreTag "$abi-$(Get-PythonWheelTag)"
    # setuptools package data contains x86 launchers that the arch gate correctly rejects.
    Get-ChildItem -LiteralPath (Join-Path $site 'setuptools') -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    return [pscustomobject]@{ HostPython = $hostPython; Extras = $legExtras }
}

function Add-Arm64PythonStageLegs {
foreach ($leg in $legs) {
    $ft = $leg.EndsWith('t')
    $abi = Get-StageAbiTag $leg
    $pythonLeg = Initialize-Arm64StageLegPython -leg $leg -ft $ft
    $site = $pythonLeg.Site
    $exe = $pythonLeg.Exe
    $wheel = @(Get-PythonAppWheelFile -Directory $wheels | Where-Object { $_.Name -match "-($abi|none)-[^-]+\.whl$" })[0]
    if (-not $wheel) { throw "no $abi or pure wheel for Python $leg in $wheels" }
    $installed = Install-Arm64StageLegSite -leg $leg -ft $ft -abi $abi -site $site -wheel $wheel
    $hostPython = $installed.HostPython
    $legExtras = $installed.Extras
    $binary = $wheel.Name -notmatch '-none-any\.whl$'
    # The proof's check, load or prove, and a refusal of any wheel but this leg's cpXY[t] one for the target.
    $check = if ($binary) { Get-NativeWheelCheck -Name $wheel.Name -Leg $leg -Platform (Get-PythonWheelTag) } else { 'load' }
    $scripts = New-StageLegScript -Leg $leg -Exe $exe[0].Name -Distribution $distribution -Check $check -TestEnv (Split-PythonCiList -Value $TestEnv) `
        -TestPaths (Split-PythonCiList -Value $TestPaths)
    Set-Content -LiteralPath (Join-Path $out "run-pytest-$leg.cmd") -Value $scripts.Run -Encoding ascii
    $manifest.Add([ordered]@{ exe = "run-pytest-$leg.cmd"; args = @(); kind = 'pytest' })
    if ($binary) {
        & uv pip install --quiet --target (Join-Path $out "proof-$leg") --python $hostPython --python-platform $platform --python-version ($leg -replace 't$', '') --no-deps $wheel.FullName
        if ($LASTEXITCODE -ne 0) { throw "unpacking $($wheel.Name) for its proof failed (exit $LASTEXITCODE)" }
        Set-Content -LiteralPath (Join-Path $out "prove-$leg.cmd") -Value $scripts.Proof -Encoding ascii
        $manifest.Add([ordered]@{ exe = "prove-$leg.cmd"; args = @(); kind = 'exitcode' })
    }
    if ($ft -and $binary -and $suite) {
        # The leg's site is the tests' only environment, so it must hold their extra.
        if ($suite.Extra -and $legExtras.Count -gt 0 -and $suite.Extra -notin $legExtras) {
            throw "the free-threaded wheel tests need the '$($suite.Extra)' extra, which the $leg leg does not install ($($legExtras -join ', '))"
        }
        $manifest.Add((New-FreeThreadedWheelTestStage -Suite $suite -RepoRoot $repo -StageDir $out -Name "wheel-tests-$leg" `
                    -Python "python-$leg\$($exe[0].Name)" -Wheel $wheel.Name))
    } elseif ($ft -and $binary) {
        Write-Host "Python ${leg}: free-threaded wheel tests skipped: pyproject.toml has no [tool.antfrastructure.free-threaded-wheel-tests]"
    }
}
}

Add-Arm64PythonStageLegs

foreach ($rel in Get-StageTestFile -RepoRoot $repo -TestFiles $TestFiles) {
    $staged = Join-Path $out "run\$rel"
    Initialize-PythonAppDirectory -Path (Split-Path $staged -Parent)
    Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $staged -Recurse
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\build\Invoke-StagedTests.ps1') -Destination $out
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\..\..\linux\scripts\02-toolchain\python\free-threaded-wheel.py') -Destination $out
ConvertTo-Json -InputObject @($manifest) -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'tests.json') -Encoding utf8
$names = @(Get-ChildItem -LiteralPath $wheels -File).Name -join ', '
& robocopy.exe $out $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "copying the stage to $dest failed (robocopy exit $LASTEXITCODE)" }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Staged $($legs.Count) leg(s) for windows-11-arm in ${dest}: $names"
