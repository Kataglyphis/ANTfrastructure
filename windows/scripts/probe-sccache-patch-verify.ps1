#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Builds sccache at the pinned rev WITH the local quote-protection patch
    (windows/upstream/sccache-nvcc-quote-fix) and re-runs the single-TU
    replay as a regression test. Expected verdict: bare == wrapped symbols.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-scc',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache patch verify nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$rev = $env:SCCACHE_GIT_REV
if (-not $rev) { throw 'SCCACHE_GIT_REV missing' }
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
if (-not (Test-Path 'src\.git')) {
    & git init -q src
    Set-Location src
    & git remote add origin https://github.com/mozilla/sccache
    & git fetch -q --depth 1 origin $rev
    if ($LASTEXITCODE -ne 0) { throw "fetch failed ($LASTEXITCODE)" }
    & git checkout -q FETCH_HEAD
} else { Set-Location src }

$patch = Get-ChildItem 'C:\bkmnt\patch\*.patch' | Select-Object -First 1
if (-not $patch) { throw 'patch file not mounted' }
& git apply --check $patch.FullName
if ($LASTEXITCODE -ne 0) { throw "patch does not apply ($LASTEXITCODE)" }
& git apply $patch.FullName
Write-Host "applied: $($patch.Name)"

Write-Host 'cargo build --release --locked (this takes a while, cold deps)...'
& cargo build --release --locked 2>&1 | Select-Object -Last 5 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
$exe = Join-Path (Get-Location) 'target\release\sccache.exe'
if (-not (Test-Path $exe)) { throw 'built sccache.exe missing' }

# Regression: same single-TU replay, patched binary under test.
& 'C:\bkmnt\probe-onnx-tu-replay.ps1' -SccacheExe $exe -Nonce $Nonce
