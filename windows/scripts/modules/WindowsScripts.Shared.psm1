Set-StrictMode -Version Latest

# Shim to make Kataglyphis.Scripts.Common available via the old relative path
function Get-MyLibraryModulesRoot {
    # Walk upwards from this script directory to find a MyLibrary/modules directory
    $dir = $PSScriptRoot
    while ($dir) {
        $candidate = Join-Path $dir 'MyLibrary\modules'
        if (Test-Path $candidate) { return $candidate }
        $parent = Split-Path -Parent $dir
        if ($parent -and ($parent -ne $dir)) { $dir = $parent } else { break }
    }
    return $null
}

try {
    Import-Module Kataglyphis.Scripts.Common -Force -ErrorAction Stop
} catch {
    $modulesRoot = Get-MyLibraryModulesRoot
    if ($modulesRoot) {
        $psm1 = Join-Path $modulesRoot 'Kataglyphis.Scripts.Common\Kataglyphis.Scripts.Common.psm1'
        if (Test-Path $psm1) { Import-Module $psm1 -Force; return }
    }
    throw $_
}

Export-ModuleMember -Function @(
    'Get-MyLibraryModulesRoot'
)
