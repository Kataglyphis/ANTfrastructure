$publisher = "CN=Jonas Heinle"
$passwordString = "YOUR_TOP_SECRET_PW"
$pfxPath = "C:\\Users\\XXX\\Documents\\MSIX_Cert.pfx"

# 1. Generate a modern self-signed certificate using a modern KSP
$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $publisher `
    -KeyUsage DigitalSignature `
    -FriendlyName "My MSIX Signing Cert" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -Provider "Microsoft Software Key Storage Provider" `
    -HashAlgorithm SHA256

# 2. Convert your plain-text password to a SecureString
$securePassword = ConvertTo-SecureString -String $passwordString -Force -AsPlainText

# 3. Export to a modern .pfx file
Export-PfxCertificate `
    -Cert $cert `
    -FilePath $pfxPath `
    -Password $securePassword `
    -CryptoAlgorithmOption AES256_SHA256 
    # Note: -CryptoAlgorithmOption is available in newer PowerShell versions. 
    # If it fails, just remove that line; the default on Win10/11 is still modern enough.

Write-Host "Modern PFX generated successfully at $pfxPath"