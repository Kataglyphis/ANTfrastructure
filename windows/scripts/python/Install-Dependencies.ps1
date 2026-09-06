# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Param(
    # Empty = resolve from the canonical pin (versions.env LLVM_WINDOWS_VERSION).
    # The old hardcoded default sat a full major behind the source of truth
    # (21.1.1 vs 22.1.8) with no scanner watching .ps1 literals in this lane —
    # and versions.env documents that five patches are clang-version-sensitive.
    [string]$ClangVersion = ''
)

Write-Host "=== Installing build dependencies on Windows ==="

$ErrorActionPreference = 'Stop'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
if ([string]::IsNullOrWhiteSpace($ClangVersion)) {
    Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path $scriptAssetRoot '..\..\linux\scripts\01-core\versions.env')
    $ClangVersion = $pins['LLVM_WINDOWS_VERSION']
    if ([string]::IsNullOrWhiteSpace($ClangVersion)) { throw 'LLVM_WINDOWS_VERSION not found in versions.env' }
}

Write-Host "Installing LLVM/Clang $ClangVersion..."
winget install --accept-source-agreements --accept-package-agreements --id=LLVM.LLVM -v $ClangVersion -e

Write-Host "Installing Ninja via winget..."
winget install --accept-source-agreements --accept-package-agreements --id=Ninja-build.Ninja -e

# NOTE: Standard uv install pattern -- downloads and executes script without checksum verification
Write-Host "Installing Astral UV..."
pwsh -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

Write-Host "=== Dependency installation completed ==="

