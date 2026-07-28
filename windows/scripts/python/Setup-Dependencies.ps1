# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

Param(
    [string]$ClangVersion = '21.1.1'
)

Write-Host "=== Installing build dependencies on Windows ==="

$ErrorActionPreference = 'Stop'

Write-Host "Installing LLVM/Clang $ClangVersion..."
winget install --accept-source-agreements --accept-package-agreements --id=LLVM.LLVM -v $ClangVersion -e

Write-Host "Installing Ninja via winget..."
winget install --accept-source-agreements --accept-package-agreements --id=Ninja-build.Ninja -e

# NOTE: Standard uv install pattern -- downloads and executes script without checksum verification
Write-Host "Installing Astral UV..."
pwsh -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"

Write-Host "=== Dependency installation completed ==="
