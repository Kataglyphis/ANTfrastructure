#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# One harness suite under TestHarness alone, a fast mutation proof; not covered: modules only Invoke-Tests imports, Pester-style suites, coverage.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Only
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -Force -DisableNameChecking
Reset-TestState
. (Join-Path $PSScriptRoot $Only)
$results = @(Get-TestResult)
$failed = @($results | Where-Object { -not $_.Ok })
Write-Host "$Only`: $($results.Count - $failed.Count)/$($results.Count) passed"
if ($failed.Count -gt 0 -or $results.Count -eq 0) { exit 1 }
exit 0
