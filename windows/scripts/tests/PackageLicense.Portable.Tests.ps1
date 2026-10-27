#requires -Version 7.0
# These tests stage a project licence; they do not build an MSI or validate third-party coverage.
Import-Module (Join-Path $PSScriptRoot 'WindowsMsixLicenseFixture.psm1') -DisableNameChecking -ErrorAction Stop
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules/WindowsMsix.Common.psm1') -DisableNameChecking -ErrorAction Stop

Describe 'portable Windows package licence staging' {
  It 'copies original bytes and rejects missing or empty project terms' {
    Invoke-InTestDir -Body { param($dir) Assert-TestPackageLicense -Root $dir }
  }
}
