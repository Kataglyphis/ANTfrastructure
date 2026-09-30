#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# Not dead code: see docs/windows-build-invariants.md § The "unreferenced" windows/scripts modules are external-consumer API

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# Invoke-BuildExternal and Write-BuildLogWarning come from here; a standalone consumer needs this import.
if (-not (Get-Module -Name 'WindowsBuild.Common')) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

function Invoke-ToolchainChecks {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [hashtable]$ToolArguments,
        [string[]]$RequiredTools = @(),
        [switch]$FailOnMissingRequiredTools,
        [string[]]$ToolOrder = @('cmake', 'clang-cl', 'flutter', 'cargo', 'ninja')
    )

    $tools = @{
        'cmake'    = @('--version')
        'clang-cl' = @('--version')
        'flutter'  = @('--version')
        'cargo'    = @('--version')
        'ninja'    = @('--version')
    }

    # Guarded: $ToolArguments may be $null or not expose .Count.
    if ($ToolArguments) {
        try {
            $ta = @($ToolArguments)
            if ($ta.Count -gt 0) {
                $tools = $ToolArguments
            }
        } catch {
            Write-Verbose "ToolArguments count probe failed, keeping defaults: $($_.Exception.Message)"
        }
    }

    $failedTools = New-Object System.Collections.Generic.List[string]

    $orderedTools = New-Object System.Collections.Generic.List[string]
    foreach ($tool in $ToolOrder) {
        if ($tools.ContainsKey($tool)) {
            $orderedTools.Add($tool) | Out-Null
        }
    }

    $remainingTools = @($tools.Keys | Where-Object { $orderedTools -notcontains $_ } | Sort-Object)
    foreach ($tool in $remainingTools) {
        $orderedTools.Add($tool) | Out-Null
    }

    foreach ($tool in $orderedTools) {
        $toolFailed = $false

        try {
            Invoke-BuildExternal -Context $Context -File $tool -Parameters $tools[$tool] | Out-Null
        } catch {
            Write-BuildLogWarning -Context $Context -Message "$tool failed, continuing. Details: $($_.Exception.Message)"
            $toolFailed = $true
        }

        if ($toolFailed) {
            $failedTools.Add($tool) | Out-Null
        }
    }

    if ($FailOnMissingRequiredTools) {
        if ($RequiredTools) {
            $failedRequired = @($RequiredTools | Where-Object { $failedTools -contains $_ })
        $failedRequired = @($failedRequired)
        if ($failedRequired.Count -gt 0) {
            throw "Required toolchain checks failed: $($failedRequired -join ', ')"
        }
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ToolchainChecks'
)

