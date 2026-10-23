#requires -Version 7.0
# Named operation checks share registration and mutation execution without coupling their assertion bodies.

Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -ErrorAction Stop

function Invoke-TestMutationChecks {
    param([Parameter(Mandatory)][Collections.IDictionary[]]$Check,
        [scriptblock]$ArgumentsFactory = { param($item) $item.Arguments })
    $register = Get-Command It -CommandType Function
    $execute = Get-Command Invoke-TestFunctionMutations -CommandType Function
    foreach ($item in $Check) {
        if ([string]::IsNullOrWhiteSpace($item.Name)) { throw 'Mutation check requires a nonempty Name' }
        $operation = $item
        & $register $item.Name {
            $arguments = & $ArgumentsFactory $operation
            if ($arguments -isnot [Collections.IDictionary]) { throw 'Mutation check arguments must be one dictionary' }
            & $execute @arguments -IncludeControl
        }.GetNewClosure()
    }
}

Export-ModuleMember -Function Invoke-TestMutationChecks
