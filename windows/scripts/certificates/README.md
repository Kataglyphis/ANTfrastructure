# MSIX signing certificate

## Generate

`GenerateCertificateMSIX.ps1 -Password <pw>` creates a self-signed DEV signing
certificate (subject from `-Publisher`) and exports it as a password-protected
PFX (`-PfxPath`, default `Documents\MSIX_Cert.pfx`). A manual utility; run it
with your own values.

## Sign with it

`Invoke-MsixPackage -Sign` (`WindowsMsix.Common`) needs `-SigningRoot`, the
directory that holds the `.pfx` — normally the repository root, where `*.pfx`
is gitignored. It signs with the first `*.pfx` there (non-recursive) and reads
the password from `MSIX_PFX_PASSWORD` (`MSIX_CERT_PASSWORD` as the fallback).

## Trust it, then install a test-signed package

`Add-AppxPackage` accepts a package signed by a **self-signed** certificate once
that certificate is in `LocalMachine\TrustedPeople`; `Root` is not needed. That
covers `GenerateCertificateMSIX.ps1`'s certificate and the per-build test
certificate OmniAccelerANT's packagers write beside an `.msix` as `-testcert.cer`.
From an **elevated** PowerShell:

```pwsh
$pfxPath = 'MSIX_Cert.pfx'   # the .pfx GenerateCertificateMSIX.ps1 wrote
$password = ConvertTo-SecureString -String '<PFX_PASSWORD>' -Force -AsPlainText
Import-PfxCertificate -FilePath $pfxPath -Password $password -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'
# or, for a public certificate: Import-Certificate -FilePath '<package>-testcert.cer' -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'

Add-AppxPackage -Path '<package>.msix'
```

OmniAccelerANT's [`Test-OmniAccelerANTInstallers.ps1`](https://github.com/Kataglyphis/OmniAccelerANT/blob/develop/scripts/windows/Test-OmniAccelerANTInstallers.ps1) installs its MSIX this way, with
a fresh self-signed certificate per run, on `windows-2025` and `windows-11-arm`.

`LocalMachine\Root` is needed only in two cases:

- **The signing certificate was issued by a CA**, a test CA included: that CA goes into
  `Root`.
- **`signtool verify /pa`**, which builds the chain to a trusted root:
  `windows/scripts/python/New-PythonAppPackage.ps1` imports its test `.cer` into `Root`
  for that check and removes it afterwards.

When the install fails:

- `0x800B0109` (`CERT_E_UNTRUSTEDROOT`): the chain ends in a root nothing trusts. A
  self-signed certificate is missing from `LocalMachine\TrustedPeople`, or a CA-issued
  one's CA is missing from `LocalMachine\Root`.
- `Import-PfxCertificate: Access denied`: the shell is not elevated.
- `Get-AppxLog -ActivityID <ACTIVITY_ID>` prints the detail behind the last deploy
  failure; the ID is in the `Add-AppxPackage` error.
