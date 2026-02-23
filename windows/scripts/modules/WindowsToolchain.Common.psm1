Set-StrictMode -Version Latest

function Invoke-ToolchainChecks {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [hashtable]$ToolArguments,
        [string[]]$RequiredTools = @(),
        [switch]$FailOnMissingRequiredTools,
        [string[]]$ToolOrder = @('cmake', 'clang-cl', 'flutter', 'cargo', 'ninja')
    )

    $tools = if ($ToolArguments -and $ToolArguments.Count -gt 0) {
        $ToolArguments
    } else {
        @{
            'cmake'    = @('--version')
            'clang-cl' = @('--version')
            'flutter'  = @('--version')
            'cargo'    = @('--version')
            'ninja'    = @('--version')
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

    if ($FailOnMissingRequiredTools -and $RequiredTools.Count -gt 0) {
        $failedRequired = @($RequiredTools | Where-Object { $failedTools -contains $_ })
        if ($failedRequired.Count -gt 0) {
            throw "Required toolchain checks failed: $($failedRequired -join ', ')"
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ToolchainChecks'
)
