#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    PR hygiene for the sccache quote fix: fmt --check, clippy, and the nvcc
    grouping unit tests (incl. the new escaped-quotes regression test) on the
    patched pin, in-container (the host has no MSVC linker).
#>
[CmdletBinding()]
param(
    [string]$WorkDir = 'C:\probe-scc',
    [string]$Nonce = ''
)
$ErrorActionPreference = 'Stop'
Write-Host "=== sccache PR hygiene nonce=$Nonce ==="
Import-Module 'C:\bkmnt\modules\WindowsSourceBuild.Common.psm1' -Force
Enter-VsDevCmdEnvironment

$rev = $env:SCCACHE_GIT_REV
if (-not $rev) {
    # Post-#50 images may not bake this key into Machine env - the file
    # itself ships at C:\temp\versions.env, read the pin from there.
    $rev = (Select-String -Path 'C:\temp\versions.env' -Pattern '^SCCACHE_GIT_REV=(.+)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
}
if (-not $rev) { throw 'SCCACHE_GIT_REV missing (env AND C:\temp\versions.env)' }
Write-Host "pin: $rev"
$null = New-Item -ItemType Directory -Force -Path $WorkDir
Set-Location $WorkDir
& git init -q src; Set-Location src
& git remote add origin https://github.com/mozilla/sccache 2>$null
& git fetch -q --depth 1 origin $rev
& git checkout -q FETCH_HEAD
$patch = Get-ChildItem 'C:\bkmnt\patch\*.patch' | Select-Object -First 1
& git apply $patch.FullName
if ($LASTEXITCODE -ne 0) { throw "patch apply failed ($LASTEXITCODE)" }
Write-Host "applied: $($patch.Name)"

& cargo fmt --check 2>&1 | Select-Object -First 5 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "cargo fmt --check FAILED ($LASTEXITCODE)" }
Write-Host '[ OK ] cargo fmt --check clean'

& cargo clippy --lib --tests --locked 2>&1 | Select-String 'warning.*generated|error' | Select-Object -Last 4 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "clippy FAILED ($LASTEXITCODE)" }
Write-Host '[ OK ] clippy clean (lib+tests)'

& cargo test --locked --lib nvcc::test::test_group_nvcc_subcommands 2>&1 | Select-String 'test result|running|passed|FAILED|panicked' | Select-Object -Last 5 | ForEach-Object { "$_" }
if ($LASTEXITCODE -ne 0) { throw "cargo test FAILED ($LASTEXITCODE)" }
Write-Host '[ OK ] nvcc grouping tests green (incl. escaped-quotes regression)'
