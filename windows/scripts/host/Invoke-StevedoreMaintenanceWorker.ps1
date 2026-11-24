#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
[CmdletBinding()]
param([switch]$ReportOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$env:PATH = [Environment]::GetFolderPath('System')
try {
    Import-Module (Join-Path $PSScriptRoot 'modules\WindowsStevedoreDelegation.Security.psm1') -ErrorAction Stop
    Assert-DelegatedMaintenanceAdministrator 'The protected maintenance worker requires elevation.'
    Import-Module (Join-Path $PSScriptRoot 'modules\WindowsStevedoreDelegation.Task.psm1') -ErrorAction Stop
    $result = Invoke-DelegatedMaintenanceWorker -Root $PSScriptRoot -ReportOnly:$ReportOnly
    $result | ConvertTo-Json -Depth 12
    exit $result.raw_exit
} catch { Write-Error ($_ | Out-String); exit 1 }
