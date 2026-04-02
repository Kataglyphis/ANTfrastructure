Adjust password and certificate location accordingly.

## Import certificate

Later it can be imported like this.

```powershell
$pfxPath = "C:\path\to\your\MSIX_Cert.pfx"
$password = ConvertTo-SecureString -String "YOUR_PW" -Force -AsPlainText
Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" -Password $password
```