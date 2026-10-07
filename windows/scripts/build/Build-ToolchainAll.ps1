#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT


# The host CPython compile of Dockerfile.toolchain-builder's `built` stage; see docs/windows-build-lanes.md § Build isolation and CPU parallelism.

[CmdletBinding()]
param(
    # The image takes both defaults; another checkout and install root prove the build without touching the baked ones.
    [string]$SourceDir = 'C:\temp\cpython',
    [string]$FreeThreadedRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$src = $SourceDir

Write-Host "==> Building CPython from source at $src (NUMBER_OF_PROCESSORS=$env:NUMBER_OF_PROCESSORS)"
if (-not (Test-Path $src)) { throw "CPython source tree missing at $src (builder image did not clone it)" }

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force

# The `built` mount list carries this module and its WindowsTargetArch dependency.
$sourceBuildModulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name 'WindowsSourceBuild.Common')) { Import-Module $sourceBuildModulePath }
# WU spool writes land in the layer and kill its finalize; no-op outside a container.
Disable-ContainerWindowsUpdate

# The NUGET_* pins are baked into the base's Machine env, so a fresh versions.env (sibling mount first) must beat them.
$versionsEnvFile = ''
foreach ($cand in @((Join-Path $scriptAssetRoot 'versions.env'),
        $(if ($env:TEMP_DIR) { Join-Path $env:TEMP_DIR 'versions.env' }))) {
    if ($cand -and (Test-Path $cand)) { $versionsEnvFile = $cand; break }
}
if ($versionsEnvFile) {
    # As in Import-Versions.ps1: the file beats baked values, a deliberately forwarded value beats the file.
    Write-Host "Overriding process env from fresh $versionsEnvFile (baked values only; forwarded overrides win)"
    foreach ($entry in (ConvertFrom-VersionsEnv -Path $versionsEnvFile).GetEnumerator()) {
        $procVal = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        $machVal = [Environment]::GetEnvironmentVariable($entry.Key, 'Machine')
        if ($procVal -and $procVal -ne $machVal -and $procVal -ne $entry.Value) {
            Write-Host "  keeping forwarded $($entry.Key)=$procVal (file has $($entry.Value))"
        } else {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
}

$nugetExe = Join-Path $src 'externals\nuget.exe'
# Pre-seeded so find_python.bat skips aka.ms/nugetclidl, which intermittently serves an HTML error page.
$nugetVer = if ($env:NUGET_VERSION) { $env:NUGET_VERSION } else { '7.9.0' }
$nugetUrl = "https://dist.nuget.org/win-x86-commandline/v$nugetVer/nuget.exe"
if (-not (Test-Path $nugetExe)) {
    # -ExpectSignature MZ rejects and retries an HTML error page served in place of the binary.
    Invoke-DownloadWithRetry -Url $nugetUrl `
        -DestinationPath $nugetExe -Description "nuget.exe $nugetVer (CPython build bootstrap)" `
        -ExpectSignature MZ -ExpectedSha256 ([string]$env:NUGET_EXE_SHA256)
    Write-Host "Pre-seeded valid nuget.exe ($([int]((Get-Item $nugetExe).Length / 1KB)) KB) at $nugetExe"
}
# find_python.bat's own fallback download, should the seed ever be absent.
$env:NUGET_URL = $nugetUrl

# -p x64 on every lane: this is the build interpreter, the toolchain image is shared, and Build-TargetCpython.ps1 builds the target one.
Invoke-CpythonPcbuild -SourceDir $src
$pyExe = "$src\PCbuild\amd64\python.exe"
if (-not (Test-Path $pyExe)) { throw 'Python build failed - interpreter not found' }

# The 3.14t legs' interpreter, from the same checkout while its externals are still here; see docs/windows-builds.md § The free-threaded CPython.
Invoke-CpythonPcbuild -SourceDir $src -FreeThreaded
if (-not $FreeThreadedRoot) { $FreeThreadedRoot = Get-CpythonFreeThreadedRoot }
Install-CpythonFreeThreadedLayout -SourceDir $src -Destination $FreeThreadedRoot -LayoutPython $pyExe

# The external DLLs are already copied into PCbuild\amd64 and the free-threaded install.
foreach ($d in @("$src\PCbuild\obj", "$src\externals", "$src\.git", (Get-CpythonFreeThreadedBuildDir -SourceDir $src))) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# After the scrub, so both interpreters are proven without the trees it removed.
Assert-CpythonInterpreter -Exe $pyExe -ExpectedVersion $env:PYTHON_VERSION
Assert-CpythonInterpreter -Exe (Join-Path $FreeThreadedRoot (Get-CpythonFreeThreadedExeName)) -FreeThreaded -ExpectedVersion $env:PYTHON_VERSION
Write-Host "Python built at: $pyExe; free-threaded at: $FreeThreadedRoot"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0
