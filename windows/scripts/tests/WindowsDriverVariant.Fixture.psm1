#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

function Get-DriverVariantDeclaredArg {
    param([string]$Dockerfile, [string]$NamePattern = '\w+')
    $path = Join-Path (Get-RepoRoot) $Dockerfile
    if (-not (Test-Path -LiteralPath $path)) { throw "$Dockerfile does not exist, but the driver solves it" }
    return @(Select-String -LiteralPath $path -Pattern "^ARG ($NamePattern)" -CaseSensitive | ForEach-Object { $_.Matches[0].Groups[1].Value })
}

function Get-DriverVariantPin {
    return ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
}

Export-ModuleMember -Function Get-DriverVariantDeclaredArg, Get-DriverVariantPin
