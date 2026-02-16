Set-StrictMode -Version Latest

function Invoke-ToolchainChecks {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [hashtable]$ToolArguments
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

    foreach ($tool in $tools.Keys) {
        Invoke-BuildOptional -Context $Context -Name $tool -Script {
            Invoke-BuildExternal -Context $Context -File $tool -Parameters $tools[$tool]
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-ToolchainChecks'
)
