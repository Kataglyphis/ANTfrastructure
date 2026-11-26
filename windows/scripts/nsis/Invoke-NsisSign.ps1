#requires -Version 7.0
<#
  .SYNOPSIS
    Sign one makensis output for !finalize and !uninstfinalize; any failure exits 1, so makensis stops.
  .DESCRIPTION
    The PFX password comes from MSIX_PFX_PASSWORD or MSIX_CERT_PASSWORD in the inherited environment, never
    from the makensis command line. See docs/adopting-in-a-new-project.md#nsis-setups
#>
param(
  [Parameter(Mandatory)] [string]$Path,
  [Parameter(Mandatory)] [string]$PfxPath,
  [Parameter(Mandatory)] [string]$LogDir
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
foreach ($module in 'WindowsScripts.Shared.psm1', 'WindowsBuild.Common.psm1', 'WindowsConfig.Common.psm1', 'WindowsMsix.Common.psm1', 'WindowsMsix.Signing.psm1') {
  Import-Module (Join-Path $moduleRoot $module) -DisableNameChecking -ErrorAction Stop
}

try {
  $context = New-BuildContext -Workspace (Split-Path -Parent $Path) -LogDir $LogDir
  [void](Invoke-AuthenticodeSign -Context $context -Path $Path -PfxPath $PfxPath -Verify Signer -Require)
  exit 0
} catch {
  [Console]::Error.WriteLine("Invoke-NsisSign: $($_.Exception.Message)")
  exit 1
}
