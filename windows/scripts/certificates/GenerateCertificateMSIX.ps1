# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Generate a modern self-signed MSIX DEV-signing certificate (KSP provider)
# and export it as a password-protected PFX. Template/utility script — run
# manually with your own values.

#requires -Version 7.0

# PSSA suppression, justified: throwaway self-signed DEV certificate; the
# password is a caller-supplied parameter of a local, manual utility (same
# rationale as New-MsixPackage.ps1 / WindowsMsix.Signing.psm1).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'dev/test signing cert; manual utility')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'dev/test signing cert; manual utility')]
param(
    [Parameter(Mandatory)][string]$Password,
    [string]$Publisher = 'CN=Jonas Heinle',
    [string]$PfxPath = (Join-Path $env:USERPROFILE 'Documents\MSIX_Cert.pfx')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 1. Generate a modern self-signed certificate using a modern KSP
$cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $Publisher `
    -KeyUsage DigitalSignature `
    -FriendlyName "My MSIX Signing Cert" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -Provider "Microsoft Software Key Storage Provider" `
    -HashAlgorithm SHA256

# 2. Convert the password to a SecureString
$securePassword = ConvertTo-SecureString -String $Password -Force -AsPlainText

# 3. Export to a modern .pfx file
Export-PfxCertificate `
    -Cert $cert `
    -FilePath $PfxPath `
    -Password $securePassword `
    -CryptoAlgorithmOption AES256_SHA256

Write-Host "Modern PFX generated successfully at $PfxPath"
