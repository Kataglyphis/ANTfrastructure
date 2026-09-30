#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Manual utility: a self-signed MSIX dev-signing certificate exported as a password-protected PFX.


# Suppressed: a throwaway dev certificate whose password the caller supplies.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'dev/test signing cert; manual utility')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'dev/test signing cert; manual utility')]
param(
    [Parameter(Mandatory)][string]$Password,
    [string]$Publisher = 'CN=Jonas Heinle',
    [string]$PfxPath = (Join-Path $env:USERPROFILE 'Documents\MSIX_Cert.pfx')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$securePassword = ConvertTo-SecureString -String $Password -Force -AsPlainText

Export-PfxCertificate `
    -Cert $cert `
    -FilePath $PfxPath `
    -Password $securePassword `
    -CryptoAlgorithmOption AES256_SHA256

Write-Host "Modern PFX generated successfully at $PfxPath"
