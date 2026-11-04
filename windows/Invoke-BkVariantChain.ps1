#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Builds and pushes several Windows variants in one run; -ConcurrentPush takes each upload off the next build's path.
.DESCRIPTION
    See docs/windows-builds.md § Several variants in one run.
.PARAMETER BuildOption
    Driver parameters for the builds that cannot change the final solve, e.g. @{ ConcurrentAux = $true }.
.EXAMPLE
    .\windows\Invoke-BkVariantChain.ps1 -Repository ghcr.io/kataglyphis/kataglyphis_beschleuniger -ConcurrentPush
#>
[CmdletBinding()]
param(
    [ValidateSet('default', 'nvidia', 'rocm')]
    [string[]]$Variant = @('default', 'nvidia', 'rocm'),
    [Parameter(Mandatory)][string]$Repository,
    # The driver validates the arch, and it owns the full stage list.
    [string]$TargetArch = 'amd64',
    [string[]]$Stages,
    [string[]]$BuildArg,
    [hashtable]$BuildOption = @{},
    [switch]$ConcurrentPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'scripts\modules\WindowsBkVariantChain.Common.psm1') -Force

$driver = Join-Path $PSScriptRoot 'Build-Buildkit.ps1'
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\windows-build-logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$now = Get-Date
$chainId = $now.ToString('yyyyMMdd-HHmmss')
if (-not $Stages) { $Stages = Get-BkDriverDefaultStage -DriverPath $driver }
$request = @{
    Variant = $Variant; Repository = $Repository; TargetArch = $TargetArch; Stages = $Stages; BuildArg = @($BuildArg); BuildOption = $BuildOption
    ChainId = $chainId; BuildDate = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$plan = @(Get-BkVariantChainPlan -Request $request -ConcurrentPush:$ConcurrentPush)

Invoke-BkVariantChain -Plan $plan -ConcurrentPush:$ConcurrentPush -InvokeBuild {
    param([hashtable]$Parameters)
    & $driver @Parameters
} -StartPush {
    param($Step)
    $log = Join-Path $logDir "bk-$chainId-push-$($Step.Name)-console"
    # Start-Process -ArgumentList joins with spaces and never quotes, so spaced paths would split.
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $driver) + $Step.PushArguments |
        ForEach-Object { if ("$_" -match '\s') { '"{0}"' -f $_ } else { "$_" } }
    $process = Start-Process -FilePath ((Get-Process -Id $PID).Path) -ArgumentList $arguments -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput "$log.out.log" -RedirectStandardError "$log.err.log"
    Write-Host "[chain] $($Step.PushRef) pushing beside the next variant (pid $($process.Id)); console: $log.*.log" -ForegroundColor Cyan
    return $process
}
Write-Host "[chain] $chainId done: $(($plan | ForEach-Object PushRef) -join ', ')" -ForegroundColor Green
exit 0
