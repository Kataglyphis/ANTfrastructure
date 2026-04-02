Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

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
            # If accessing Count fails, ignore and keep defaults
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
