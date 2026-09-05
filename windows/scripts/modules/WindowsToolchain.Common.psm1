#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# NOTE (downstream consumers -- do NOT remove as "dead code"): this module has no
# callers inside THIS repo, but Kataglyphis-Inference-Engine's
# scripts/windows/Build-Windows.ps1 imports it from its ContainerHub submodule at
# third_party/ContainerHub/windows/scripts/modules/. It was deleted
# once in 5be9b1e and restored (2026-07-15) -- grep known consumers before any
# future sweep of windows/scripts/modules/.

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, WITHOUT -Force (repo-wide nested-import rule, 2026-08-04): a forced
# nested re-import rebinds the dependency into THIS module's private scope and
# unloads the caller's top-level import — the PS module-scoping trap that broke
# the BuildDriver test suite and forced build-gstreamer's import-Shared-twice
# workaround. Trade-off (accepted): a long-lived dev session that edits Shared
# must Remove-Module/reimport manually; containers always start fresh.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# Invoke-BuildExternal and Write-BuildLogWarning (used inside this module's own
# catch handler!) come from the sibling WindowsBuild.Common module; without this
# import a standalone consumer hits CommandNotFound at runtime. Guarded,
# WITHOUT -Force, for the same nested-import rule as above.
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

    # Default tool commands
    $tools = @{
        'cmake'    = @('--version')
        'clang-cl' = @('--version')
        'flutter'  = @('--version')
        'cargo'    = @('--version')
        'ninja'    = @('--version')
    }

    # If ToolArguments was provided and looks like a collection with a Count, use it.
    # Avoid accessing .Count on objects that may be $null or don't expose that property
    if ($ToolArguments) {
        try {
            $ta = @($ToolArguments)
            if ($ta.Count -gt 0) {
                $tools = $ToolArguments
            }
        } catch {
            # If accessing Count fails, keep defaults.
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

