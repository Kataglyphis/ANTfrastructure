#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
    Installs the hub's pinned Flutter SDK on a Windows runner and puts it on the job's PATH.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsFlutterPin.Common.psm1') -Force

$bin = Install-PinnedFlutterSdk -Destination $Destination
if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin }
& (Join-Path $bin 'flutter.bat') --version
if ($LASTEXITCODE) { throw 'flutter --version failed' }
