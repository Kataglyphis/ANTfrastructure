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

## Import certificate

Adjust password and certificate location accordingly. Later it can be imported
like this.

```pwsh
$pfxPath = "C:\path\to\your\MSIX_Cert.pfx"
$password = ConvertTo-SecureString -String "YOUR_PW" -Force -AsPlainText
Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" -Password $password
```
