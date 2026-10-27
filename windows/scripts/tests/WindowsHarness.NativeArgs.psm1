#requires -Version 7.0
# Native tools require separate ordered argv tokens even when a value contains spaces.
Set-StrictMode -Version Latest

function Assert-TestNativeArgOrder {
    param([string[]]$Arguments, [string]$First, [string]$Second, [switch]$Adjacent)
    $before = [array]::IndexOf($Arguments, $First)
    $after = [array]::IndexOf($Arguments, $Second)
    if ($before -lt 0 -or $after -le $before -or ($Adjacent -and $after -ne $before + 1)) {
        throw "Native argv must contain $First before $Second with the expected separation"
    }
}

Export-ModuleMember -Function Assert-TestNativeArgOrder
