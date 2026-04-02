Set-StrictMode -Version Latest

# Reuse shared helpers defined in WindowsScripts.Shared.psm1 to avoid duplicating
# Get-MyLibraryModulesRoot and related logic across multiple module files.
try {
    $sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
    if (Test-Path $sharedPath) { . $sharedPath }
} catch {
    # Non-fatal; we'll still attempt the module import fallback below.
}

try {
    Import-Module Kataglyphis.Scripts.Logging -Force -ErrorAction Stop
} catch {
    # Get-MyLibraryModulesRoot should be available from the shared script; if not, the
    # fallback walk-up still works because the shared script defines it.
    $modulesRoot = Get-MyLibraryModulesRoot
    if ($modulesRoot) {
        $psm1 = Join-Path $modulesRoot 'Kataglyphis.Scripts.Logging\Kataglyphis.Scripts.Logging.psm1'
        if (Test-Path $psm1) { Import-Module $psm1 -Force; return }
    }
    throw $_
}
