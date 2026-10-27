#requires -Version 7.0
# Project-licence staging is testable on every host without Windows packaging tools.
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -DisableNameChecking -ErrorAction Stop

function Assert-TestPackageLicense {
  param([Parameter(Mandatory)][string]$Root)
  $source = Join-Path $Root 'source terms.txt'
  [IO.File]::WriteAllBytes($source, [byte[]](0xef, 0xbb, 0xbf, 0x4d, 0x49, 0x54, 0x0a))
  $copy = Copy-PackageLicense -Path $source -Destination (Join-Path $Root 'payload[one]')
  Assert-Equal (Join-Path $Root 'payload[one]/LICENSE') $copy
  Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($source))) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($copy)))
  $other = Join-Path $Root 'other'
  Assert-Throws -MessagePattern 'not found' -Body { Copy-PackageLicense -Path (Join-Path $Root 'missing') -Destination $other }
  $empty = Join-Path $Root 'empty'
  [IO.File]::WriteAllText($empty, " `n")
  Assert-Throws -MessagePattern 'is empty' -Body { Copy-PackageLicense -Path $empty -Destination $other }
  Assert-False (Test-Path -LiteralPath $other)
}

Export-ModuleMember -Function Assert-TestPackageLicense
