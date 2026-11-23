#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: MIT
# Sets RustDesk's permanent password, which RustDesk never displays again; see docs/windows-host-setup.md § F3.

[CmdletBinding()]
param(
    # Omit it to be asked twice without an echo.
    [securestring]$Password
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsRustDesk.Common.psm1')

Assert-Elevated -Reason 'rustdesk.exe --password needs admin'
$exe = Get-RustDeskExe

if (-not $Password) {
    $Password = Read-Host -AsSecureString 'New RustDesk password'
    $repeat = Read-Host -AsSecureString 'Repeat it'
    if ([Net.NetworkCredential]::new('', $Password).Password -cne [Net.NetworkCredential]::new('', $repeat).Password) {
        throw 'The two entries differ; the password is unchanged'
    }
}

Set-RustDeskPermanentPassword -Exe $exe -Password $Password
$method = Get-RustDeskOption -Exe $exe -Name 'verification-method'
Write-Host 'Permanent password set.' -ForegroundColor Green
# An unset method accepts both passwords; only use-temporary-password locks the permanent one out.
if ($method -eq 'use-temporary-password') {
    Write-Host "verification-method is '$method', so the new password is refused; choose the permanent one in Settings > Security." -ForegroundColor Yellow
}
