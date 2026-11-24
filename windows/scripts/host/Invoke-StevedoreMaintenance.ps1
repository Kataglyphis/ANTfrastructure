#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
[CmdletBinding()]
param([switch]$Apply, [switch]$Status, [ValidateRange(0, 3600)][int]$WaitSeconds = 300)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsStevedoreDelegation.Task.psm1') -ErrorAction Stop
    if ($Status) {
        if ($Apply) { throw 'Status is read-only and cannot be combined with Apply.' }
        @(Get-DelegatedMaintenanceStatus) | ConvertTo-Json -Depth 12
        exit 0
    }
    $result = Start-DelegatedMaintenance -Apply:$Apply -WaitSeconds $WaitSeconds
    $result | ConvertTo-Json -Depth 12
    if ($result.state -eq 'submitted-not-completed') { exit 2 }
    exit $result.raw_exit
} catch { Write-Error ($_ | Out-String); exit 1 }
