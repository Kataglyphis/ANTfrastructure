# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0
# The target interpreter never runs here, so its in-stage PE checks are the only proof; see docs/windows-cross-builds.md § The target CPython is built from source (#120 step 1).

param(
    [string]$SourceDir = 'C:\temp\cpython',
    [string]$InstallDir = '',
    # media-tvm's C:\runtime\python* never reaches the merge, and TVM links only PCbuild\<arch>.
    [switch]$SkipFreeThreaded
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$tgtArch = Get-WindowsTargetArch
if (-not (Test-WindowsCrossTarget -Arch $tgtArch)) {
    # Kept in the chain on amd64 too, so -ResumeFrom/-Until names stay lane-independent.
    Write-Host 'Target CPython: host == target on amd64 — the toolchain PCbuild\amd64 build already serves as the target interpreter. Nothing to do.'
    exit 0
}

trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'target-cpython'; break }

Switch-BuildPhase '1. preconditions'
$buildBat = Join-Path $SourceDir 'PCbuild\build.bat'
if (-not (Test-Path $buildBat)) {
    throw ("Target CPython: $buildBat not found. The toolchain layer ships the CPython SOURCE tree " +
           '(it is the deliverable); if it is absent this image predates that contract or the tree was scrubbed.')
}
$hostPy = Get-SourceBuildPython
if (-not (Test-Path $hostPy.Exe)) { throw "Target CPython: host build interpreter missing at $($hostPy.Exe) — build.bat needs it via `$env:PYTHON" }
$propsFile = Join-Path $SourceDir 'PCbuild\Directory.Build.props'
if (-not (Test-Path $propsFile)) {
    # The ARM64 build needs the ClangCL toolset props the toolchain layer drops here.
    $shipped = Join-Path $scriptAssetRoot 'cpython-Directory.Build.props'
    if (Test-Path $shipped) { Copy-Item $shipped $propsFile } else { throw "Target CPython: $propsFile missing and no shipped props to restore" }
}
$cpyBuildPlatform = Get-CpythonBuildPlatform -Arch $tgtArch   # 'ARM64'
$cpyOutDir = Join-Path $SourceDir "PCbuild\$(Get-CpythonOutputDir -Arch $tgtArch)"  # ...\PCbuild\arm64
Write-Host "Target CPython: building -p $cpyBuildPlatform (ClangCL toolset) from $SourceDir; output -> $cpyOutDir"

Switch-BuildPhase '2. externals'
# Own phase so a failed externals fetch (build.bat -e) is not blamed on the build.
$env:PYTHON = $hostPy.Exe
$externals = Join-Path $SourceDir 'externals'
if (Test-Path $externals) {
    Write-Host "externals already present at $externals (unexpected on this image, but fine)"
} else {
    Write-Host 'externals absent (deleted by the toolchain layer after the host build) — build.bat -e will fetch them'
}

Switch-BuildPhase '3. PCbuild -p ARM64 (ClangCL)'
# Without PreferredToolArchitecture=x64 MSBuild may pick an arm64-hosted toolchain that cannot run here.
$hostToolArgs = @('"/p:PreferredToolArchitecture=x64"')
Invoke-CpythonPcbuild -SourceDir $SourceDir -Platform $cpyBuildPlatform -ExtraArguments $hostToolArgs

Switch-BuildPhase '4. verify + stage into the bundle'
$redistArm64 = Get-ChildItem 'C:\Program Files*\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\arm64\Microsoft.VC*.CRT' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
$redistDir = if ($redistArm64) { $redistArm64.FullName } else { '' }
$gil = Install-CpythonTargetTree -BuildDir $cpyOutDir -SourceDir $SourceDir -Destination (Join-Path $InstallDir 'python') -Arch $tgtArch `
    -RedistDir $redistDir -BundleBin (Join-Path $InstallDir 'bin') -ShimWrittenBy 'Build-TargetCpython.ps1 (TARGET interpreter, #125)'
$summary = "GIL tree $($gil.Files) files"

if ($SkipFreeThreaded) {
    Write-Host 'Target CPython: -SkipFreeThreaded, so this branch builds no free-threaded tree'
} else {
    # After the GIL tree is staged, so nothing this build writes into the source tree can reach it.
    Switch-BuildPhase '5. PCbuild -p ARM64 --disable-gil (ClangCL)'
    Invoke-CpythonPcbuild -SourceDir $SourceDir -Platform $cpyBuildPlatform -FreeThreaded -ExtraArguments $hostToolArgs

    Switch-BuildPhase '6. verify + stage the free-threaded tree'
    # Its own prefix, like the image's C:\python-freethreaded: no python.exe and an empty site-packages; see docs/windows-builds.md § The free-threaded CPython.
    $ft = Install-CpythonTargetTree -BuildDir (Get-CpythonFreeThreadedBuildDir -SourceDir $SourceDir -Arch $tgtArch) -SourceDir $SourceDir `
        -Destination (Join-Path $InstallDir 'python-freethreaded') -Arch $tgtArch -FreeThreaded -RedistDir $redistDir
    $summary += ", free-threaded tree $($ft.Files) files ($(Split-Path $ft.Exe -Leaf))"
    # Unlike PCbuild\arm64, nothing links against the free-threaded build output later.
    Remove-Item (Get-CpythonFreeThreadedBuildDir -SourceDir $SourceDir) -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Target CPython: $summary"

Switch-BuildPhase '7. scrub'
# PCbuild\arm64 stays: Get-TargetBuildPython resolves link inputs there for later consumer builds.
foreach ($d in @("$SourceDir\externals", "$SourceDir\PCbuild\obj")) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'target-cpython'
Write-Host '=== Target CPython build completed ==='
exit 0
