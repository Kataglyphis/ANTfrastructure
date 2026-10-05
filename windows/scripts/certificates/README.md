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

A self-signed certificate must be trusted machine-wide before `Add-AppxPackage`
accepts a package it signed. That means **both** `LocalMachine\Root` and
`LocalMachine\TrustedPeople`, from an **elevated** PowerShell:

```pwsh
$pfxPath = 'MSIX_Cert.pfx'   # the .pfx GenerateCertificateMSIX.ps1 wrote
$password = ConvertTo-SecureString -String '<PFX_PASSWORD>' -Force -AsPlainText
Import-PfxCertificate -FilePath $pfxPath -Password $password -CertStoreLocation 'Cert:\LocalMachine\Root'
Import-PfxCertificate -FilePath $pfxPath -Password $password -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople'

Add-AppxPackage -Path '<package>.msix'
```

When the install fails:

- `0x800B0109`: the certificate chain is not trusted. `TrustedPeople` alone is not
  enough; import into `Root` as well, as above.
- `Import-PfxCertificate: Access denied`: the shell is not elevated.
- `Get-AppxLog -ActivityID <ACTIVITY_ID>` prints the detail behind the last deploy
  failure; the ID is in the `Add-AppxPackage` error.
