#requires -Version 7.2
# The real .NET sender verifies OAEP interoperability with OpenSSL using disposable test inputs.
param(
    [Parameter(Mandatory)][string]$PublicKeyFile,
    [Parameter(Mandatory)][string]$ExpectedFingerprint,
    [Parameter(Mandatory)][string]$PlaintextFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$rsa = [System.Security.Cryptography.RSA]::Create()
$plain = $null
try {
    $rsa.ImportFromPem([System.IO.File]::ReadAllText($PublicKeyFile))
    $der = $rsa.ExportSubjectPublicKeyInfo()
    $fingerprint = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($der)).ToLowerInvariant()
    if ($fingerprint -cne $ExpectedFingerprint) { throw 'Public key fingerprint mismatch' }
    $plain = [System.IO.File]::ReadAllBytes($PlaintextFile)
    $cipher = $rsa.Encrypt($plain, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    [System.Convert]::ToBase64String($cipher)
}
finally {
    $rsa.Dispose()
    if ($null -ne $plain) { [System.Array]::Clear($plain, 0, $plain.Length) }
}
