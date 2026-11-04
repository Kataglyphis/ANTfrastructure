#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# See docs/windows-builds.md § Several variants in one run

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsTargetArch.Common.psm1')

# Only knobs that cannot change the final solve, so a build and its push child stay one cache key.
$script:BuildOnlyOption = @('MediaMemoryGb', 'HostReserveGb', 'ConcurrentAux', 'LatestApp', 'MinFreeGb', 'NoResourceLog')

function Assert-BkVariantChainRequest {
    param([string[]]$Variant, [string]$TargetArch, [string[]]$Stages, [string[]]$BuildArg, [hashtable]$BuildOption, [bool]$ConcurrentPush)
    if ($Variant.Count -eq 0) { throw 'name at least one variant' }
    $repeated = @($Variant | Group-Object | Where-Object Count -GT 1 | ForEach-Object Name)
    if ($repeated.Count -gt 0) { throw "variant named twice: $($repeated -join ', ')" }
    if ($TargetArch -ne 'amd64' -and $Variant -contains 'rocm') { throw "rocm is amd64-only; refused before any variant builds (-TargetArch $TargetArch)" }
    if ($Stages -notcontains 'final') { throw "a chain pushes each variant's final image, but -Stages $($Stages -join ',') builds none" }
    $unknown = @($BuildOption.Keys | Where-Object { $_ -notin $script:BuildOnlyOption })
    if ($unknown.Count -gt 0) { throw "-BuildOption $($unknown -join ', ') is not a build-only knob; allowed: $($script:BuildOnlyOption -join ', ')" }
    # pwsh -File delivers one string for an array: docs/windows-build-invariants.md § Never cross a pwsh process boundary with an array parameter.
    if ($ConcurrentPush -and $BuildArg.Count -gt 1) { throw '-ConcurrentPush passes -BuildArg over a process boundary, which holds one KEY=VALUE; use the serial mode for more' }
}

function Get-BkVariantChainStep {
    param([string]$Name, [string]$Repository, [string]$TargetArch, [string[]]$Stages, [string[]]$BuildArg, [hashtable]$BuildOption, [string]$ChainId, [string]$BuildDate)
    $isDefault = $Name -eq 'default'
    $tag = (Get-WindowsTargetTagSuffix -Arch $TargetArch) + $(if ($isDefault) { '' } else { "-$Name" })
    $pushRef = "${Repository}:$tag"
    $build = @{ TargetArch = $TargetArch; BuildDate = $BuildDate; Stages = $Stages; BuildArg = $BuildArg } + $BuildOption
    $pushArgs = @('-TargetArch', $TargetArch, '-BuildDate', $BuildDate, '-Stages', 'final', '-PushOnly', '-PushRef', $pushRef, '-ParentRunId', $ChainId, '-NoResourceLog')
    if (-not $isDefault) {
        $build['Variant'] = $Name
        $pushArgs += @('-Variant', $Name)
    }
    foreach ($arg in $BuildArg) { $pushArgs += @('-BuildArg', $arg) }
    return [pscustomobject]@{ Name = $Name; PushRef = $pushRef; BuildParameters = $build; PushArguments = [string[]]$pushArgs }
}

<#
.SYNOPSIS
    One step per variant: the driver's in-process build parameters and its push child's -File arguments.
#>
function Get-BkVariantChainPlan {
    param(
        [Parameter(Mandatory)][string[]]$Variant,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][ValidatePattern('^\d{8}-\d{6}$')][string]$ChainId,
        [Parameter(Mandatory)][string]$BuildDate,
        [string]$TargetArch = 'amd64',
        [string[]]$Stages = @('base', 'sdk', 'toolchain', 'media', 'migraphx', 'llama', 'torch', 'final'),
        [string[]]$BuildArg = @(),
        [hashtable]$BuildOption = @{},
        [switch]$ConcurrentPush
    )
    Assert-BkVariantChainRequest -Variant $Variant -TargetArch $TargetArch -Stages $Stages -BuildArg $BuildArg -BuildOption $BuildOption -ConcurrentPush ([bool]$ConcurrentPush)
    foreach ($name in $Variant) {
        Get-BkVariantChainStep -Name $name -Repository $Repository -TargetArch $TargetArch -Stages $Stages -BuildArg $BuildArg `
            -BuildOption $BuildOption -ChainId $ChainId -BuildDate $BuildDate
    }
}

function Get-BkFailedPush {
    param([object[]]$Push)
    @($Push | Where-Object { $_.Process.HasExited -and $_.Process.ExitCode -ne 0 } |
            ForEach-Object { "$($_.Name) push failed (exit $($_.Process.ExitCode), $($_.PushRef))" })
}

function Invoke-BkVariantBuildStep {
    # Returns the failure text, so the caller can still wait for pushes already under way.
    param([object]$Step, [scriptblock]$InvokeBuild, [scriptblock]$StartPush, [bool]$ConcurrentPush, [System.Collections.Generic.List[object]]$Push)
    $parameters = $Step.BuildParameters.Clone()
    if (-not $ConcurrentPush) { $parameters['PushRef'] = $Step.PushRef }
    try {
        & $InvokeBuild $parameters | Out-Host
        if ($ConcurrentPush) {
            $process = & $StartPush $Step
            $Push.Add([pscustomobject]@{ Name = $Step.Name; PushRef = $Step.PushRef; Process = $process })
        }
    } catch {
        return "$($Step.Name) failed: $($_.Exception.Message)"
    }
    return ''
}

<#
.SYNOPSIS
    Builds the plan's variants in turn; every failed build or push fails the run, and no variant starts after one.
.DESCRIPTION
    -ConcurrentPush starts each push as a child beside the next variant's build. An interrupted run kills its push trees.
#>
function Invoke-BkVariantChain {
    param(
        [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][scriptblock]$InvokeBuild,
        [scriptblock]$StartPush = { throw 'no push starter' },
        [switch]$ConcurrentPush
    )
    $push = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[string]]::new()
    $settled = $false
    try {
        foreach ($step in $Plan) {
            foreach ($f in @(Get-BkFailedPush -Push $push.ToArray())) { $failures.Add($f) }
            if ($failures.Count -gt 0) { break }
            $failure = Invoke-BkVariantBuildStep -Step $step -InvokeBuild $InvokeBuild -StartPush $StartPush -ConcurrentPush ([bool]$ConcurrentPush) -Push $push
            if ($failure) { $failures.Add($failure); break }
        }
        foreach ($p in $push) { $p.Process.WaitForExit() }
        $settled = $true
    } finally {
        if (-not $settled) { foreach ($p in $push) { if (-not $p.Process.HasExited) { $p.Process.Kill($true) } } }
    }
    foreach ($f in @(Get-BkFailedPush -Push $push.ToArray())) { if (-not $failures.Contains($f)) { $failures.Add($f) } }
    if ($failures.Count -gt 0) { throw "variant chain failed: $($failures -join '; ')" }
}

Export-ModuleMember -Function Get-BkVariantChainPlan, Invoke-BkVariantChain
